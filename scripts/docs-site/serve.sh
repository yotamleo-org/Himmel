#!/usr/bin/env bash
# scripts/docs-site/serve.sh — build the docs site and serve it for review.
#   bash scripts/docs-site/serve.sh          # build + static preview
#   bash scripts/docs-site/serve.sh --dev    # astro dev (live reload on docs/)
# Loopback only, port 4321 (never shifts to another port); site/ is the Starlight
# workspace, docs/ is its source.
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
site="$repo/site"
port=4321
host=127.0.0.1
mode=preview
[ "${1:-}" = "--dev" ] && mode=dev

if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
  echo "serve.sh: port $port is already in use on $host; free it and retry" >&2
  exit 1
fi

cd "$site" || exit 1
if [ ! -d node_modules/astro ]; then npm ci >&2 || exit 1; fi
if [ "$mode" = preview ]; then npm run build >&2 || exit 1; fi

echo "docs site: http://$host:$port/Himmel/"
exec npx astro "$mode" --host "$host" --port "$port"
