#!/usr/bin/env bash
# scripts/docs-site/test-site-build.sh — docs-site go/no-go: builds the docs site from
# docs/ as-is and asserts the four criteria of the docs-site plan.
#   1 titles come from the H1, no duplicate H1, no docs/ file edited
#   2 relative .md links resolve to site routes, repo-path links point at the
#     GitHub blob URL, a broken link fails the build
#   3 a bare <placeholder> renders as visible text
#   4 mermaid blocks reach the page and the 3 standalone HTML pages are
#     byte-identical
# Needs `npm ci` in site/ (network); without site/node_modules it skips loudly.
set -u
repo=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
here="$repo/site"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
check() { # check <desc> <command...>
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi
}

absent() { # absent <fixed-string> <file>: pass only when grep ran and found nothing (exit 1); exit 2 is an error
  grep -qF -- "$1" "$2" >/dev/null 2>&1
  [ $? -eq 1 ]
}
fails() { ! "$@"; }

if [ ! -d "$here/node_modules/astro" ]; then
  echo "SKIP: site/node_modules absent (run: cd site && npm ci); needs network, not run in the hermetic shell shards"
  exit 0
fi

ctl=$(mktemp -d -t site-build-ctl.XXXXXX) || exit 1
trap 'rm -rf "$ctl"' EXIT
echo present >"$ctl/page"
check "control: absent() passes when the text is missing" absent nope "$ctl/page"
check "control: absent() fails when the text is present" fails absent present "$ctl/page"
check "control: absent() fails on an unreadable file" fails absent nope "$ctl/no-such-file"

cd "$here" || exit 1
rm -rf dist
if npm run build >"$here/.build.log" 2>&1; then ok "npm run build exits 0"; else
  ko "npm run build exits 0"
  tail -20 "$here/.build.log"
fi
dist="$here/dist"
allow=$(grep -vE '^[[:space:]]*(#|$)' "$here/allowlist.txt")

route_of() { # docs-relative .md path -> dist html path
  local r=${1%.md}
  r=${r%README}
  r=${r%/}
  if [ -z "$r" ]; then echo "$dist/index.html"; else echo "$dist/$r/index.html"; fi
}

# --- criterion 1: titles from the H1, no duplicate H1
c1=1
while IFS= read -r f; do
  page=$(route_of "$f")
  h1=$(grep -m1 '^# ' "$repo/docs/$f" | sed 's/^# //; s/`//g')
  t=$(grep -o '<title>[^<]*' "$page" | head -1 | sed 's/<title>//')
  case "$t" in "$h1"*) ;; *) c1=0; echo "  title mismatch $f: want '$h1' got '$t'" ;; esac
  [ "$(grep -o '<h1' "$page" | wc -l)" -eq 1 ] || { c1=0; echo "  $f: h1 count != 1"; }
done <<<"$allow"
if [ "$c1" -eq 1 ]; then ok "criterion 1: titles from H1, exactly one h1 per page"; else ko "criterion 1: titles from H1, exactly one h1 per page"; fi
check "criterion 1: only the two dangling-link docs are edited" test "$(git -C "$repo" status --porcelain -- docs | awk '{print $2}' | sort | tr '\n' ' ')" = "docs/internals/handover-system.md docs/security-review.md " -o -z "$(git -C "$repo" status --porcelain -- docs)"

# --- criterion 2: links
md_pages=$(grep -rlE --include=index.html 'href="(/|\.)[^"#]*\.md["#]' "$dist"; echo "rc=$?")
check "criterion 2: no site-local href ends in .md" test "$md_pages" = "rc=1"
check "control: the .md scan had pages to read" test -n "$(find "$dist" -name index.html -print -quit 2>/dev/null)"
check "criterion 2: .md link rewritten to its route" grep -q 'href="/Himmel/setup/install/"' "$(route_of getting-started.md)"
check "criterion 2: repo-path link points at the GitHub blob URL" grep -q 'href="https://github.com/yotamleo/himmel/blob/main/CLAUDE.md"' "$(route_of getting-started.md)"
c2=1
nlinks=0
while IFS= read -r h; do
  nlinks=$((nlinks + 1))
  p=${h%%[#?]*}
  p=${p#/Himmel}
  if [ -e "$dist$p" ] && [ -f "$dist$p" ]; then continue; fi
  [ -f "$dist${p%/}/index.html" ] || { c2=0; echo "  dead internal link $h"; }
done < <(grep -rhoE --include=index.html 'href="/Himmel/[^"]*"' "$dist" | sed 's/^href="//; s/"$//' | sort -u | grep -vE '/_astro/|/pagefind/|favicon|sitemap')
[ "$nlinks" -gt 0 ] || { c2=0; echo "  no internal hrefs found in dist"; }
if [ "$c2" -eq 1 ]; then ok "criterion 2: every internal href resolves in dist"; else ko "criterion 2: every internal href resolves in dist"; fi
# control: the remark step throws on a link to a file that does not exist
broken=$(cd "$here" && node --input-type=module -e "
import { remarkDocs } from './src/plugins/remark-docs.mjs';
const t = { type: 'root', children: [{ type: 'link', url: './no-such-page.md', children: [] }] };
try { remarkDocs({ base: '/Himmel', allow: [], html: [] })(t, { path: '$repo/docs/getting-started.md' }); console.log('no-throw'); }
catch (e) { console.log('threw: ' + e.message); }")
case "$broken" in threw:*broken\ link*) ok "criterion 2: a broken link fails the build ($broken)" ;; *) ko "criterion 2: a broken link fails the build (got: $broken)" ;; esac

# --- criterion 3: bare <placeholder> stays visible text
check "criterion 3: bare <name> renders as visible text" grep -qE 'Console (&#x3C;|&lt;)name(>|&gt;) is live' "$(route_of telegram-bridge.md)"
check "criterion 3: no <name> element swallowed into the DOM" absent 'Console <name>' "$(route_of telegram-bridge.md)"

# --- criterion 4: mermaid + byte-identical standalone HTML
want=$(grep -c '^```mermaid' "$repo/docs/architecture.md")
got=$(grep -o '<pre class="mermaid"' "$(route_of architecture.md)" | wc -l)
if [ "$want" -gt 0 ] && [ "$want" -eq "$got" ]; then ok "criterion 4: $got mermaid blocks reach the page"; else ko "criterion 4: mermaid blocks reach the page (docs $want, page $got)"; fi
check "criterion 4: mermaid renderer is bundled" grep -rlq 'mermaid' "$dist/_astro"
for h in adoption-trail.html guide/installer-journey.html guide/loops-and-graphs.html; do
  check "criterion 4: $h byte-identical" cmp "$repo/docs/$h" "$dist/$h"
done

# --- J1: full site (one page per IA section, trail page, raw passthrough, search)
for r in daily-loop handover/overnight-mode glossary internals/stuck-playbook contributing; do
  check "J1: IA page /$r/ built" test -f "$dist/$r/index.html"
done
check "J1: /adoption-trail.html served" test -f "$dist/adoption-trail.html"
for raw in setup/install.md setup/settings-template.json setup/profiles/operator.install-profile.json; do
  check "J1: raw $raw byte-identical" cmp "$repo/docs/$raw" "$dist/$raw"
done
c_raw=1
while IFS= read -r f; do
  cmp -s "$repo/docs/$f" "$dist/$f" || { c_raw=0; echo "  raw copy differs: $f"; }
done <<<"$allow"
if [ "$c_raw" -eq 1 ]; then ok "J1: every allowlisted .md is served raw at its path"; else ko "J1: every allowlisted .md is served raw at its path"; fi
check "J1: Pagefind index built" test -f "$dist/pagefind/pagefind.js"
hit=$(cd "$here" && node --input-type=module -e "
import fs from 'node:fs';
const pf = await import('file://$dist/pagefind/pagefind.js');
const origFetch = globalThis.fetch;
globalThis.fetch = (u, o) => String(u).startsWith('file:') ? Promise.resolve(new Response(fs.readFileSync(new URL(u)))) : origFetch(u, o);
await pf.options({ basePath: 'file://$dist/pagefind/' });
const r = await pf.search('stuck playbook');
const d = await Promise.all(r.results.slice(0, 5).map((x) => x.data()));
console.log(d.map((x) => x.url).join(' '));" 2>&1)
case "$hit" in *stuck-playbook*) ok "J1: Pagefind hit for 'stuck playbook' ($hit)" ;; *) ko "J1: Pagefind hit for 'stuck playbook' (got: $hit)" ;; esac

rm -f "$here/.build.log"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
