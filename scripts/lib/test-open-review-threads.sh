#!/usr/bin/env bash
# scripts/lib/test-open-review-threads.sh - suite for open-review-threads.sh
# the count and the names come from every page, the cursor is
# sent, a stuck or failed read is rc 1, and gh's {owner}/{repo} placeholders go
# through -F. Hermetic: a stub gh script runs the caller's own --jq on fixture
# JSON; no network. bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/open-review-threads.sh
. "$HERE/open-review-threads.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/open-review-threads-test.XXXXXX")" || { echo "FAIL: mktemp -d"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails + 1)); fi; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails + 1)) ;; esac; }

# page 1: 100 resolved threads and a next page; page 2: one resolved, one open.
th_node() { printf '{"isResolved":%s,"path":"%s","line":%s,"originalLine":%s,"comments":{"nodes":[{"author":{"login":"%s"},"createdAt":"%s"}]}}' "$@"; }
p1="" i=0
while [ "$i" -lt 100 ]; do
    p1="$p1${p1:+,}$(th_node true "docs/f$i.md" "$i" "$i" human 2026-11-09T04:00:00Z)"
    i=$((i + 1))
done
printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[%s]}}}}}' "$p1" > "$tmp/page1.json"
printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":"c2"},"nodes":[%s,%s]}}}}}' \
    "$(th_node true README.md 1 1 human 2026-11-09T04:10:00Z)" \
    "$(th_node false scripts/jira/src/policy.ts null 88 coderabbitai 2026-11-09T05:07:51Z)" > "$tmp/page2.json"

cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/args.log"
q="" prev="" page=page1
for a in "$@"; do
    [ "$prev" = --jq ] && q=$a
    [ "$a" = c=c1 ] && page=page2
    prev=$a
done
case "${STUB_MODE:-ok}" in
    fail) echo "graphql boom" >&2; exit 1 ;;
    stuck) page=page1 ;;
    garbage) echo "not a page"; exit 0 ;;
esac
jq -r "$q" "$STUB_DIR/$page.json"
STUB
chmod +x "$tmp/gh"
export STUB_DIR="$tmp"

rc=0; out=$(open_review_threads octo demo 5053 "$tmp/gh") || rc=$?
check "a two-page read is rc 0" "$rc" 0
check "the count is summed over both pages (the open thread is on page 2)" "${out%%$'\n'*}" 1
contains "the page-2 thread is named, its line read from originalLine" "$out" "scripts/jira/src/policy.ts:88 by coderabbitai at 2026-11-09T05:07:51Z"
case "$out" in *README.md*|*docs/f*) check "no resolved thread is named" named none ;; *) check "no resolved thread is named" none none ;; esac
check "two pages were read" "$(wc -l < "$tmp/args.log" | tr -d ' ')" 2
contains "the second read sent page 1's cursor" "$(sed -n 2p "$tmp/args.log")" "c=c1"
contains "a plain owner goes through -f" "$(sed -n 1p "$tmp/args.log")" "-f o=octo"

: > "$tmp/args.log"
rc=0; open_review_threads '{owner}' '{repo}' 5053 "$tmp/gh" >/dev/null || rc=$?
check "placeholder owner/repo read rc 0" "$rc" 0
contains "gh's {owner} placeholder goes through -F" "$(sed -n 1p "$tmp/args.log")" "-F o={owner} -F r={repo}"

rc=0; STUB_MODE=stuck open_review_threads octo demo 5053 "$tmp/gh" >/dev/null || rc=$?
check "a cursor that does not advance is rc 1" "$rc" 1
rc=0; STUB_MODE=fail open_review_threads octo demo 5053 "$tmp/gh" >/dev/null || rc=$?
check "a failed query is rc 1" "$rc" 1
rc=0; STUB_MODE=garbage open_review_threads octo demo 5053 "$tmp/gh" >/dev/null || rc=$?
check "a malformed page is rc 1" "$rc" 1
rc=0; open_review_threads octo demo 05053 "$tmp/gh" >/dev/null || rc=$?
check "a PR number with a leading zero is rc 1" "$rc" 1

[ "$fails" -eq 0 ] && { echo "PASS: test-open-review-threads.sh"; exit 0; }
echo "FAIL: $fails case(s)"
exit 1
