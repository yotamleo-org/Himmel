#!/usr/bin/env bash
# Suite for docs/guide/second-model-review.md, the user page on the review.
#
# The page states review rules and where the review runs. Both drift when the
# code moves, so every claim is pinned to the tree:
#
#   1. CITES   — every rule bullet under "What a finding does" carries a
#                <!-- source: ... --> comment, and every path any source
#                comment names exists in the tree.
#   2. NOW     — the page text carries no "for now" reach tag.
#   3. REACH   — "In your own project" holds while scripts/adopt.sh
#                PORTABLE_FILES copies in the merge gate's reviewer check;
#                "ships with the himmel checkout, not your project" holds while
#                it does not copy .claude/commands/pr-check.md; the HIMMEL_REPO
#                claim holds while pr-check-context.sh has the adopter lane.
#   4. CONTROL — a fixture page citing a missing script fails case 1, and one
#                with a "for now" tag fails case 2, so neither passes vacuously.
#
# Usage: bash scripts/docs/test-second-model-review-page.sh [page.md]
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PAGE="${1:-$ROOT/docs/guide/second-model-review.md}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

# Prints one problem per line; prints nothing when every citation holds.
cite_problems() {
  python3 -I - "$1" "$ROOT" <<'PY' || echo "could not read $1"
import os, re, sys
page, root = sys.argv[1], sys.argv[2]
text = open(page, encoding="utf-8").read()
m = re.search(r"^## What a finding does\n(.*?)(?=^## )", text, flags=re.S | re.M)
if not m:
    print("no 'What a finding does' section")
else:
    for line in m.group(1).splitlines():
        if line.startswith("- ") and "<!-- source:" not in line:
            print("rule without a source comment: " + line[:80])
cites = re.findall(r"<!--\s*source:\s*(.*?)\s*-->", text, flags=re.S)
if not cites:
    print("no source comments")
for c in cites:
    for path in (p.strip() for p in c.split(",")):
        if not os.path.isfile(os.path.join(root, path)):
            print("cited file missing: " + path)
PY
}

# The page text with every <!-- comment --> removed.
page_text() {
  python3 -I -c 'import re,sys; sys.stdout.write(re.sub(r"<!--.*?-->", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S))' "$1"
}

# An unreadable page counts as carrying the tag, so NOW never passes on no text.
has_for_now() { local t; t=$(page_text "$1") || return 0; grep -qi 'for now' <<< "$t"; }

# The PORTABLE_FILES array of scripts/adopt.sh, one path per line.
portable_files() {
  sed -n '/^PORTABLE_FILES=(/,/^)/p' "$ROOT/scripts/adopt.sh" | sed -e 's/^[[:space:]]*//' -e '/^PORTABLE_FILES=(/d' -e '/^)/d' -e '/^#/d' -e '/^$/d'
}

if [ ! -f "$PAGE" ]; then
  bad "page exists" "$PAGE"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# 1. CITES
problems=$(cite_problems "$PAGE")
if [ -z "$problems" ]; then ok "CITES: every rule cites a file that exists"; else bad "CITES: every rule cites a file that exists" "$problems"; fi

# 2. NOW
if has_for_now "$PAGE"; then bad "NOW: no 'for now' reach tag" "$(page_text "$PAGE" | grep -i 'for now')"; else ok "NOW: no 'for now' reach tag"; fi

# 3. REACH
portable=$(portable_files)
# One line, single spaces, so a phrase matches across the page's line wraps.
text=$(page_text "$PAGE" | tr -s ' \n' '  ')
missing=""
for f in scripts/hooks/block-unresolved-cr-merge.sh scripts/lib/review-merge-gate.sh scripts/cr/critics.json; do
  grep -qxF "$f" <<< "$portable" || missing="$missing $f"
done
if ! grep -qF '**In your own project.**' <<< "$text"; then
  bad "REACH: the page states the in-project reach"
elif [ -n "$missing" ]; then
  bad "REACH: the merge gate's reviewer check is copied into a project" "not in adopt.sh PORTABLE_FILES:$missing"
else
  ok "REACH: the merge gate's reviewer check is copied into a project"
fi
if ! grep -qF 'ships with the himmel checkout, not your project' <<< "$text"; then
  bad "REACH: the page says /pr-check stays in the himmel checkout"
elif grep -qxF .claude/commands/pr-check.md <<< "$portable"; then
  bad "REACH: /pr-check is not copied into a project" "adopt.sh now copies .claude/commands/pr-check.md: rewrite 'Where it runs'"
else
  ok "REACH: /pr-check is not copied into a project"
fi
if ! grep -qF 'HIMMEL_REPO' <<< "$text"; then
  bad "REACH: the page names the HIMMEL_REPO anchor"
elif grep -qF 'anchor_lane=adopter' "$ROOT/scripts/cr/pr-check-context.sh"; then
  ok "REACH: pr-check-context.sh reviews another repo through the anchor"
else
  bad "REACH: pr-check-context.sh reviews another repo through the anchor" "no anchor_lane=adopter in scripts/cr/pr-check-context.sh"
fi

# 4. CONTROL
fx=$(mktemp -d -t smr-page.XXXXXX) || { bad "CONTROL: mktemp"; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }
trap 'rm -rf "$fx"' EXIT
printf '## What a finding does\n\n- A rule. <!-- source: scripts/cr/no-such-script.sh -->\n\n## Next\n' >"$fx/cite.md"
if [ -n "$(cite_problems "$fx/cite.md")" ]; then ok "CONTROL: a missing cited script fails CITES"; else bad "CONTROL: a missing cited script fails CITES"; fi
printf 'It runs from your himmel clone, for now.\n' >"$fx/now.md"
if has_for_now "$fx/now.md"; then ok "CONTROL: a 'for now' tag fails NOW"; else bad "CONTROL: a 'for now' tag fails NOW"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
