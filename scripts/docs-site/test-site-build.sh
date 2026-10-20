#!/usr/bin/env bash
# selector: tree-scan
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

is() { [ "$1" = "$2" ]; }
h1() { node --input-type=module -e "import { pathToFileURL } from 'node:url'; const { h1Of } = await import(pathToFileURL(process.argv[2]).href); process.stdout.write(h1Of(process.argv[1]));" "$1" "$here/src/loaders/docs-loader.mjs"; }

# --- h1Of: markup in a heading never reaches the page title (pure node, runs without node_modules)
check "h1Of: *em* is stripped" is "$(h1 '# The *daily* loop')" "The daily loop"
check "h1Of: _em_ is stripped" is "$(h1 '# The _daily_ loop')" "The daily loop"
check "h1Of: **strong** and __strong__ are stripped" is "$(h1 '# A **bold** and __bold__ head')" "A bold and bold head"
check "h1Of: code and link markers are still stripped" is "$(h1 "# \`code\` and [link](x.md)")" "code and link"
check "control: h1Of keeps an intraword underscore" is "$(h1 '# snake_case_name stays')" "snake_case_name stays"
check "control: h1Of keeps intraword double underscores" is "$(h1 '# snake__case__name stays')" "snake__case__name stays"
check "h1Of: emphasis markers inside a code span survive" is "$(h1 "# The \`*ptr*\` field")" "The *ptr* field"
check "h1Of: a code-formatted link label is stripped to its text" is "$(h1 "# [\`foo\`](x.md) page")" "foo page"
check "h1Of: a lone backtick is dropped" is "$(h1 "# Use the \` key")" "Use the  key"
check "h1Of: a double-backtick span keeps its inner backtick" is "$(h1 "# The \`\`a\`b\`\` span")" "The a\`b span"
check "control: is() fails on a mismatch" fails is "a" "b"

# --- host sweep: the docs site and repo live under the org, so no tracked file may name the old host or slug
old_host='yotamleo\.github\.io'
old_repo='github\.com/yotamleo/himmel'
clean() { grep -qE -- "$old_host|$old_repo" "$@" >/dev/null 2>&1; [ $? -eq 1 ]; } # exit 2 (unreadable) is not clean
sweep_ctl=$(mktemp -d -t site-host-ctl.XXXXXX) || exit 1
trap 'rm -rf "$sweep_ctl"' EXIT
printf 'see https://yotamleo%s\n' '.github.io/Himmel/' >"$sweep_ctl/planted-host"
printf 'see https://github.com/yotamleo%s\n' '/himmel' >"$sweep_ctl/planted-repo"
printf 'see %s\n' 'https://yotamleo-org.github.io/Himmel/' >"$sweep_ctl/org"
check "control: sweep flags a planted old site host" fails clean "$sweep_ctl/planted-host"
check "control: sweep flags a planted old repo slug" fails clean "$sweep_ctl/planted-repo"
check "control: sweep passes the org URLs" clean "$sweep_ctl/org"
check "control: sweep fails on an unreadable file" fails clean "$sweep_ctl/no-such-file"
sweep_files=()
while read -r f; do sweep_files+=("$repo/$f"); done < <(git -C "$repo" ls-files -- docs site README.md scripts/docs-site scripts/himmelctl scripts/jira/reconcile-lib.test.mjs)
for d in docs site; do
  n=0
  for f in "${sweep_files[@]}"; do case "$f" in "$repo/$d/"*) n=$((n + 1)) ;; esac; done
  if [ "$n" -gt 0 ]; then ok "host sweep: git ls-files listed files under $d/"; else ko "host sweep: git ls-files listed files under $d/"; fi
done
check "host sweep: no tracked docs/site/wizard file names the old docs host or repo slug" clean "${sweep_files[@]}"

if [ ! -d "$here/node_modules/astro" ]; then
  echo "SKIP: site/node_modules absent (run: cd site && npm ci); needs network, not run in the hermetic shell shards"
  printf '\n%d passed, %d failed (site build not run)\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

ctl=$(mktemp -d -t site-build-ctl.XXXXXX) || exit 1
trap 'rm -rf "$ctl" "$sweep_ctl"' EXIT
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

route_of() { # docs-relative .md path -> dist html path (docs/README.md is the docs map; Home is the hero page)
  local r=${1%.md}
  [ "$r" = README ] && r=docs-map
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
if docs_status=$(git -C "$repo" status --porcelain -- docs); then
  check "criterion 1: only the permitted docs files are edited" test -z "$(printf '%s\n' "$docs_status" | awk 'NF {print $2}' | grep -vxE 'docs/(README\.md|internals/handover-system\.md|security-review\.md)')"
else
  ko "criterion 1: git status of docs failed"
fi

# --- criterion 2: links
md_pages=$(grep -rlE --include=index.html 'href="(/|\.)[^"#]*\.md["#]' "$dist"; echo "rc=$?")
check "criterion 2: no site-local href ends in .md" test "$md_pages" = "rc=1"
check "control: the .md scan had pages to read" test -n "$(find "$dist" -name index.html -print -quit 2>/dev/null)"
check "criterion 2: .md link rewritten to its route" grep -q 'href="/Himmel/setup/install/"' "$(route_of getting-started.md)"
check "criterion 2: repo-path link points at the GitHub blob URL" grep -q 'href="https://github.com/yotamleo-org/Himmel/blob/main/CLAUDE.md"' "$(route_of getting-started.md)"
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

# --- IA v4: sidebar groups equal the F1 list, hero Home with the F2 copy and CTA
groups=$(node --input-type=module -e "
import fs from 'node:fs';
const html = fs.readFileSync(process.argv[1], 'utf8');
let depth = 0;
const out = [];
for (const m of html.slice(html.indexOf('<ul class=\"top-level')).matchAll(/<(\/?)ul\b|<span class=\"large[^\"]*\">([^<]*)</g)) {
  if (m[2] !== undefined) { if (depth === 1) out.push(m[2]); continue; }
  depth += m[1] ? -1 : 1;
  if (depth === 0) break;
}
process.stdout.write(out.join('|'));" "$(route_of getting-started.md)") || groups='<node failed>'
check "IA: top-level sidebar groups equal the F1 list (got: $groups)" is "$groups" "Get started|Use it|Run many sessions|Reference|For contributors"
home="$dist/index.html"
check "IA: Home is the hero page, not the docs map" grep -q 'Let Claude Code work on its own' "$home"
check "IA: Home carries the Try it on a throwaway project CTA" grep -q 'Try it on a throwaway project' "$home"
check "IA: Home has exactly one h1" is "$(grep -o '<h1' "$home" | wc -l | tr -d ' ')" 1
check "IA: the docs map is still built" test -f "$dist/docs-map/index.html"

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
