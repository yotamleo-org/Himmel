#!/usr/bin/env bash
# scripts/docs-site/test-serve.sh — journey J1: the operator opens
# the local docs site. Runs serve.sh for real on 127.0.0.1:4321.
# Needs `npm ci` in site/ (network); without it, skips loudly.
set -u
repo=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

if [ ! -d "$repo/site/node_modules/astro" ]; then
  echo "SKIP: site/node_modules absent (run: cd site && npm ci); needs network, not run in the hermetic shell shards"
  exit 0
fi
if (exec 3<>/dev/tcp/127.0.0.1/4321) 2>/dev/null; then
  echo "SKIP: port 4321 is busy on this host; free it to run J1"
  exit 0
fi

tmp=$(mktemp -d -t docs-site-j1.XXXXXX) || exit 1
srv=""
blocker=""
up=0
cleanup() {
  # astro detaches into its own session, so kill by port: this test owns 4321 (checked free above)
  if [ -n "$srv" ]; then
    kill "$srv" 2>/dev/null
    # only once our own server answered there; a failed start must not kill a stranger
    if [ "$up" -eq 1 ]; then
      ss -ltnp 'sport = :4321' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | xargs -r kill 2>/dev/null
    fi
  fi
  [ -n "$blocker" ] && kill "$blocker" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- port busy: non-zero exit, port named, no silent shift
node -e "require('net').createServer().listen(4321,'127.0.0.1');setTimeout(()=>{},60000)" &
blocker=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>/dev/tcp/127.0.0.1/4321) 2>/dev/null && break; sleep 0.3; done
if out=$(bash "$repo/scripts/docs-site/serve.sh" 2>&1); then ko "busy port exits non-zero"; else
  case "$out" in *4321*) ok "busy port exits non-zero and names 4321" ;; *) ko "busy port names the port (got: $out)" ;; esac
fi
kill "$blocker" 2>/dev/null
wait "$blocker" 2>/dev/null
blocker=""

# --- serve for real
bash "$repo/scripts/docs-site/serve.sh" >"$tmp/out" 2>"$tmp/err" &
srv=$!
up=0
for _ in $(seq 1 120); do
  curl -fs -o /dev/null http://127.0.0.1:4321/Himmel/ 2>/dev/null && { up=1; break; }
  sleep 1
done
if [ "$up" -eq 1 ]; then ok "site answers on http://127.0.0.1:4321/Himmel/"; else ko "site answers"; tail -5 "$tmp/err"; fi
if [ "$(grep -c '^docs site: http://127.0.0.1:4321/Himmel/$' "$tmp/out")" -eq 1 ]; then ok "serve.sh prints exactly the one URL line"; else ko "serve.sh prints the URL line"; fi

for p in "" why-himmel/ getting-started/ setup/install/ adoption-trail.html; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4321/Himmel/$p")
  if [ "$code" = 200 ]; then ok "200 /Himmel/$p"; else ko "200 /Himmel/$p (got $code)"; fi
done
page=$(curl -s http://127.0.0.1:4321/Himmel/getting-started/)
if printf '%s' "$page" | grep -q 'href="/Himmel/setup/install/"'; then ok "no-JS page carries its rewritten .md link"; else ko "no-JS page carries its rewritten .md link"; fi
if printf '%s' "$page" | grep -q 'href="https://github.com/yotamleo/himmel/blob/main/CLAUDE.md"'; then ok "repo-path link points at GitHub"; else ko "repo-path link points at GitHub"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4321/Himmel/pagefind/pagefind.js)
if [ "$code" = 200 ]; then ok "search index (pagefind) is served"; else ko "search index is served (got $code)"; fi

# --- mermaid really renders, when a headless browser is present
if command -v chromium >/dev/null 2>&1; then
  dom=$(chromium --headless --no-sandbox --disable-gpu --virtual-time-budget=15000 --dump-dom http://127.0.0.1:4321/Himmel/architecture/ 2>/dev/null)
  case "$dom" in *'data-processed="true"'*) ok "mermaid renders to SVG in a headless browser" ;; *) ko "mermaid renders to SVG in a headless browser" ;; esac
else
  echo "SKIP: no chromium; mermaid render not checked in a browser"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
