#!/usr/bin/env bash
# selector: tree-scan
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

# The POST routes are the paths the 404 guard lets through (the one `path !== ... return 404` line).
routes=$(grep -E 'return new Response\("not found", \{ status: 404 \}\)' "$SERVER" | grep -oE '"/api/[a-z/-]+"' | tr -d '"' | sort -u)
if [ -z "$routes" ]; then
  bad "no POST routes found in scripts/config-ui/server.ts (the guard line moved?)"
fi

for r in $routes; do
  if grep -qF "\`$r\`" "$DOC"; then ok; else bad "docs/ui.md does not name the write route $r"; fi
done

if grep -qiE 'every page is read-only|read-only except' "$DOC"; then
  bad "docs/ui.md still carries a blanket read-only claim"
else
  ok
fi

echo "test-ui-doc-actions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
