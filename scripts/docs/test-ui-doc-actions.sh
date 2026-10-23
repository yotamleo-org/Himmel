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

if grep -qiE 'every page is read-only|read-only except|only the settings switches' "$DOC"; then
  bad "docs/ui.md still carries a blanket read-only claim"
else
  ok
fi

# Each of the ten entry pages names its audience and has an owner row.
for p in README.md docs/why-himmel.md docs/getting-started.md docs/setup/install.md docs/adoption-trail.html \
         docs/daily-loop.md docs/configuration.md docs/commands-catalog.md docs/setup/updating.md docs/ui.md; do
  if grep -E '^\|' "$DOC" | grep -F "\`$p\`" | grep -qE 'HIMMEL-[0-9]+'; then ok; else bad "docs/ui.md owner table has no owner row for $p"; fi
  case "$p" in
    *.html) ;;
    *) if grep -qE '^Audience: (newcomer|contributor)' "$ROOT/$p"; then ok; else bad "$p has no Audience: newcomer|contributor line"; fi ;;
  esac
done

echo "test-ui-doc-actions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
