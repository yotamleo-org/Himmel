#!/usr/bin/env bash
# scripts/docs-site/serve.sh — build the docs site and serve it for review.
#   bash scripts/docs-site/serve.sh          # build + static preview
# Loopback only, port 4321 (never shifts to another port); site/ is the Starlight
# workspace, docs/ is its source. Preview only: the standalone HTML pages are
# copied at build time, which astro dev never runs.
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
site="$repo/site"
port=4321
host=127.0.0.1

# astro shifts to the next port when either family is taken, so check both
check_port_free() {
  local h
  for h in "$host" ::1; do
    if (exec 3<>"/dev/tcp/$h/$port") 2>/dev/null; then
      echo "serve.sh: port $port is already in use on $h; free it and retry" >&2
      exit 1
    fi
  done
}

check_port_free

cd "$site" || exit 1
# the stamp holds the lockfile hash of the last install, so a dependency bump reinstalls
stamp=node_modules/.lockfile.sha256
lock_sha=$( (sha256sum package-lock.json 2>/dev/null || shasum -a 256 package-lock.json) | cut -d' ' -f1)
if [ -z "$lock_sha" ]; then echo "serve.sh: cannot hash site/package-lock.json" >&2; exit 1; fi
if [ ! -d node_modules/astro ] || [ "$(cat "$stamp" 2>/dev/null)" != "$lock_sha" ]; then
  npm ci >&2 || exit 1
  echo "$lock_sha" >"$stamp"
fi
npm run build >&2 || exit 1
# a dead route or fragment is reported, not fatal: the preview is for reading the pages
node "$repo/scripts/docs-site/check-built-links.mjs" dist /Himmel >&2 || echo "serve.sh: the built site has dead links (listed above)" >&2

# the build takes seconds; a process may have claimed the port meanwhile
check_port_free

echo "docs site: http://$host:$port/Himmel/"
exec npx astro preview --host "$host" --port "$port"
