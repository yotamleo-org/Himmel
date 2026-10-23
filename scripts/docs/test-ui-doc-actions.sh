#!/usr/bin/env bash
# docs/ui.md must describe the writes the local UI really makes: every POST route the
# config server accepts is named in the page, and no blanket read-only claim survives.
#
# Usage: bash scripts/docs/test-ui-doc-actions.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SERVER="$ROOT/scripts/config-ui/server.ts"
DOC="$ROOT/docs/ui.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

# ponytail: routes are read only from the single 404 guard line and the Handled-in column is unchecked, add a handler-name check if routes ever move out of that line.
# The POST routes are the paths the 404 guard lets through (the one `path !== ... return 404` line).
routes=$(grep -E 'return new Response\("not found", \{ status: 404 \}\)' "$SERVER" | grep -oE '"/api/[^"]+"' | tr -d '"' | sort -u)
if [ -z "$routes" ]; then
  bad "no POST routes found in scripts/config-ui/server.ts (the guard line moved?)"
fi

for r in $routes; do
  # a table row of the action-to-handler map, not any prose mention
  if grep -E '^\|' "$DOC" | grep -qF "\`$r\`"; then ok; else bad "docs/ui.md action table has no row for the write route $r"; fi
done

if grep -qiE 'every page is read-only|read-only except|only the settings switches|(console|ui|interface) is (entirely |fully |completely )?read-only' "$DOC"; then
  bad "docs/ui.md still carries a blanket read-only claim"
else
  ok
fi

# Each of the ten entry pages names its audience and has an owner row.
for p in README.md docs/why-himmel.md docs/getting-started.md docs/setup/install.md docs/adoption-trail.html \
         docs/daily-loop.md docs/configuration.md docs/commands-catalog.md docs/setup/updating.md docs/ui.md; do
  if grep -E '^\|' "$DOC" | grep -F "\`$p\`" | grep -qE 'HIMMEL-[0-9]+'; then ok; else bad "docs/ui.md owner table has no owner row for $p"; fi
  if grep -E '^\|' "$DOC" | grep -F "\`$p\`" | grep -qE '\| (newcomer|contributor)( and (newcomer|contributor))? \|'; then ok; else bad "docs/ui.md owner table has no audience for $p"; fi
  case "$p" in
    *.html) ;;
    *) if grep -qE '^Audience: (newcomer|contributor)' "$ROOT/$p"; then ok; else bad "$p has no Audience: newcomer|contributor line"; fi ;;
  esac
done

# Passthrough guide pages are copied raw, so a relative .md link only resolves on the site when
# that page is allowlisted; anything else must be a GitHub URL.
for g in "$ROOT/docs/guide/installer-journey.html" "$ROOT/docs/guide/loops-and-graphs.html"; do
  while IFS= read -r href; do
    if grep -qxF "$href" "$ROOT/site/allowlist.txt"; then ok; else bad "$(basename "$g") links ../$href, which the site does not build (not in site/allowlist.txt)"; fi
  done < <(grep -oE 'href="\.\./[^"#]+\.md(#[^"]*)?"' "$g" | sed -E 's/^href="\.\.\///; s/(#[^"]*)?"$//')
done

# A nested fence closed early leaves the rest of the page inside a code block, so the site loses
# every later heading anchor; the schema page must end outside any fence.
SCHEMA="$ROOT/docs/luna/end-session-wiki-schema.md"
fence_state=$(python3 -c '
import re,sys
fence=0
for line in open(sys.argv[1], encoding="utf-8"):
    m=re.match(r"^(`{3,})(.*)$", line.rstrip("\n"))
    if not m: continue
    if not fence: fence=len(m.group(1))
    elif len(m.group(1))>=fence and not m.group(2).strip(): fence=0
print("open" if fence else "closed")
' "$SCHEMA")
if [ "$fence_state" = closed ]; then ok; else bad "docs/luna/end-session-wiki-schema.md ends inside a code fence (nested fence closed early)"; fi

echo "test-ui-doc-actions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
