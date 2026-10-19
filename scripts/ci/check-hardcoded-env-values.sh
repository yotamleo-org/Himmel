#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-hardcoded-env-values.sh [<base>] — refuse NEW hardcoded environment
# values (repo/owner slugs, Pages URLs, GHCR image paths, absolute home paths,
# Atlassian hosts, Jira field ids) in the lines added by <base>...HEAD
# (default origin/main). Existing hits are the inventory in
# docs/internals/hardcoded-env-values.md; this gate only stops the class growing.
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
base="${1:-origin/main}"

[ -f "$allow" ] || { echo "check-hardcoded-env-values: allowlist missing: $allow" >&2; exit 2; }
git rev-parse --verify -q "$base^{commit}" >/dev/null || { echo "check-hardcoded-env-values: unknown base '$base'" >&2; exit 2; }

diff_out=$(git diff -U0 --no-color --diff-filter=AMR "$base"...HEAD) || { echo "check-hardcoded-env-values: git diff failed" >&2; exit 2; }
[ -n "$diff_out" ] || exit 0

printf '%s\n' "$diff_out" | awk -v allowfile="$allow" '
BEGIN {
    n = 0
    while ((getline line < allowfile) > 0) {
        if (line ~ /^[[:space:]]*(#|$)/) continue
        allow[n++] = line
    }
    close(allowfile)
    k = 0
    cls[k] = "repo-slug";     re[k++] = "yotamleo(-org)?/[A-Za-z0-9._-]+"
    cls[k] = "pages-url";     re[k++] = "[A-Za-z0-9-]+\\.github\\.io"
    cls[k] = "ghcr-image";    re[k++] = "ghcr\\.io/"
    cls[k] = "home-path";     re[k++] = "/home/[a-z][a-z0-9_-]*"
    cls[k] = "jira-host";     re[k++] = "[A-Za-z0-9}-]\\.atlassian\\.net"
    cls[k] = "jira-field-id"; re[k++] = "customfield_[0-9]+"
    nclass = k
}
/^\+\+\+ / {
    file = $0; sub(/^\+\+\+ (b\/)?/, "", file)
    skip = 0
    for (i = 0; i < n; i++) if (file ~ allow[i]) { skip = 1; break }
    next
}
/^@@ / { lineno = $0; sub(/^@@ -[0-9,]+ \+/, "", lineno); sub(/[, ].*/, "", lineno); lineno += 0; next }
/^\+/ {
    body = substr($0, 2)
    cur = lineno++
    if (skip) next
    if (body ~ /^[[:space:]]*(#|\/\/)/) next
    if (body ~ /env-literal-ok:[[:space:]]*[^[:space:]]/) next
    for (c = 0; c < nclass; c++) {
        if (body ~ re[c]) {
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
}'
