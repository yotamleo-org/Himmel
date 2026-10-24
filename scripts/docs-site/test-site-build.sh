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
#   5 every local route and #fragment in the built site resolves, passthrough
#     pages included (check-built-links.mjs, with a broken-link control)
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
clean() { grep -qiE -- "$old_host|$old_repo" "$@" >/dev/null 2>&1; [ $? -eq 1 ]; } # exit 2 (unreadable) is not clean
sweep_ctl=$(mktemp -d -t site-host-ctl.XXXXXX) || exit 1
trap 'rm -rf "$sweep_ctl"' EXIT
printf 'see https://yotamleo%s\n' '.github.io/Himmel/' >"$sweep_ctl/planted-host"
printf 'see https://github.com/yotamleo%s\n' '/Himmel' >"$sweep_ctl/planted-repo"
printf 'see %s\n' 'https://yotamleo-org.github.io/Himmel/' >"$sweep_ctl/org"
check "control: sweep flags a planted old site host" fails clean "$sweep_ctl/planted-host"
check "control: sweep flags a planted old repo slug" fails clean "$sweep_ctl/planted-repo"
check "control: sweep passes the org URLs" clean "$sweep_ctl/org"
check "control: sweep fails on an unreadable file" fails clean "$sweep_ctl/no-such-file"
sweep_files=()
while read -r f; do sweep_files+=("$repo/$f"); done < <(git -C "$repo" ls-files -- docs site README.md scripts/docs-site scripts/himmelctl/bin.js scripts/himmelctl/test/test-wizard-contributor-profile.sh scripts/jira/reconcile-lib.test.mjs)
for d in docs site; do
  n=0
  for f in "${sweep_files[@]}"; do case "$f" in "$repo/$d/"*) n=$((n + 1)) ;; esac; done
  if [ "$n" -gt 0 ]; then ok "host sweep: git ls-files listed files under $d/"; else ko "host sweep: git ls-files listed files under $d/"; fi
done
check "host sweep: no tracked docs/site/wizard file names the old docs host or repo slug" clean "${sweep_files[@]}"

# --- site URLs: derived from the repo (GITHUB_REPOSITORY, else the git origin), never written in site/
# 'yotamleo-org/Himmel' is GITHUB_REPOSITORY of this repo's own CI runs (the real value, not hand-written).
urls() { node --input-type=module -e "import { pathToFileURL } from 'node:url'; const u = await import(pathToFileURL(process.argv[1]).href); process.stdout.write(u.SITE_ORIGIN + ' ' + u.REPO_URL);" "$here/src/urls.mjs"; }
mkdir "$sweep_ctl/origin-repo" "$sweep_ctl/bare-repo" "$sweep_ctl/lookalike-repo" || exit 1
git init -q "$sweep_ctl/origin-repo" && git -C "$sweep_ctl/origin-repo" remote add origin git@github.com:Acme-Org/Widgets.git || exit 1
git init -q "$sweep_ctl/lookalike-repo" && git -C "$sweep_ctl/lookalike-repo" remote add origin https://notgithub.com/acme/widgets.git || exit 1
git init -q "$sweep_ctl/bare-repo" || exit 1
check "site urls: the CI repository gives the current Pages origin and repo URL" is "$(GITHUB_REPOSITORY=yotamleo-org/Himmel urls 2>/dev/null)" "https://yotamleo-org.github.io https://github.com/yotamleo-org/Himmel"
check "site urls: another repository gives its own, host lowercased" is "$(GITHUB_REPOSITORY=Acme-Org/Widgets urls 2>/dev/null)" "https://acme-org.github.io https://github.com/Acme-Org/Widgets"
check "site urls: no GITHUB_REPOSITORY falls back to the git origin" is "$(unset GITHUB_REPOSITORY; GIT_DIR="$sweep_ctl/origin-repo/.git" urls 2>/dev/null)" "https://acme-org.github.io https://github.com/Acme-Org/Widgets"
urls_closed() { local out rc; out=$(urls 2>/dev/null); rc=$?; [ "$rc" -ne 0 ] && [ -z "$out" ]; } # fail closed = nonzero exit AND no value
closed_lookalike() ( unset GITHUB_REPOSITORY; GIT_DIR="$sweep_ctl/lookalike-repo/.git" urls_closed )
closed_bare() ( unset GITHUB_REPOSITORY; GIT_DIR="$sweep_ctl/bare-repo/.git" urls_closed )
closed_malformed() ( GITHUB_REPOSITORY='x/y;z' GIT_DIR="$sweep_ctl/bare-repo/.git" urls_closed )
check "site urls: an origin on a lookalike host is not github.com" closed_lookalike
check "site urls: neither source fails closed" closed_bare
check "site urls: a malformed GITHUB_REPOSITORY is not trusted" closed_malformed
closed_valid() ( GITHUB_REPOSITORY=yotamleo-org/Himmel urls_closed )
check "control: urls_closed fails when urls succeeds" fails closed_valid

# --- docs edits: rename-safe. --no-renames lists a rename as a delete plus an add, so both paths are checked
docs_edits() { # docs_edits <repo>: one edited docs path per line; a git failure is a failure
  local out
  out=$(git -C "$1" status --porcelain --no-renames -- docs) || return 1
  printf '%s\n' "$out" | sed -e '/^$/d' -e 's/^...//'
}
docs_ok() { # docs_ok <repo>: only the permitted docs files are edited
  local edits
  edits=$(docs_edits "$1") || return 1
  ! printf '%s' "$edits" | grep -qvxE 'docs/(README\.md|internals/handover-system\.md|security-review\.md)'
}
docs_fixture() { # docs_fixture <dir>: a throwaway repo with one permitted and one other docs file
  mkdir -p "$1/docs" && git init -q "$1" || return 1
  echo a >"$1/docs/README.md" && echo b >"$1/docs/other.md"
  git -C "$1" add docs && git -C "$1" -c user.name=ctl -c user.email=ctl@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm init
}
docs_fixture "$sweep_ctl/docs-clean" || exit 1
check "control: docs_ok passes a clean docs tree" docs_ok "$sweep_ctl/docs-clean"
docs_fixture "$sweep_ctl/docs-permitted" || exit 1
echo more >>"$sweep_ctl/docs-permitted/docs/README.md"
check "control: docs_ok passes an edit to a permitted file" docs_ok "$sweep_ctl/docs-permitted"
docs_fixture "$sweep_ctl/docs-other" || exit 1
echo more >>"$sweep_ctl/docs-other/docs/other.md"
check "control: docs_ok fails an edit to another docs file" fails docs_ok "$sweep_ctl/docs-other"
docs_fixture "$sweep_ctl/docs-rename" || exit 1
git -C "$sweep_ctl/docs-rename" mv docs/README.md docs/stray.md
check "control: docs_ok fails a permitted file renamed to a stray path" fails docs_ok "$sweep_ctl/docs-rename"
check "control: docs_ok fails when git status fails" fails docs_ok "$sweep_ctl/no-such-repo"

# --- Pagefind hit: DIST goes through the environment, stderr stays out of the hit text, the exit status counts
pf_hit() { # pf_hit <dist>: print the top result urls for 'stuck playbook'
  (cd "$here" && DIST="$1" node --input-type=module -e "
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const base = pathToFileURL(process.env.DIST + '/pagefind/').href;
const pf = await import(base + 'pagefind.js');
const origFetch = globalThis.fetch;
globalThis.fetch = (u, o) => String(u).startsWith('file:') ? Promise.resolve(new Response(fs.readFileSync(new URL(u)))) : origFetch(u, o);
await pf.options({ basePath: base });
const r = await pf.search('stuck playbook');
const d = await Promise.all(r.results.slice(0, 5).map((x) => x.data()));
console.log(d.map((x) => x.url).join(' '));")
}
hit_ok() { # hit_ok <rc> <urls>: the search exited 0 and found the page
  [ "$1" -eq 0 ] || return 1
  case "$2" in *stuck-playbook*) return 0 ;; *) return 1 ;; esac
}
pf_run() { # pf_run <dist>: pf_hit then hit_ok, stderr dropped
  local out rc
  out=$(pf_hit "$1" 2>/dev/null)
  rc=$?
  hit_ok "$rc" "$out"
}
check "control: hit_ok passes a zero exit with the page url" hit_ok 0 "/internals/stuck-playbook/"
check "control: hit_ok fails a nonzero exit even when the text names the page" fails hit_ok 1 "/internals/stuck-playbook/"
check "control: hit_ok fails an empty result" fails hit_ok 0 ""
check "control: a missing index under a stuck-playbook path fails the search, the path text is no hit" fails pf_run "$sweep_ctl/it's a stuck-playbook dist"

# --- built links: scripts/docs-site/check-built-links.mjs fails on a dead route or fragment, passthrough pages included
links_chk="$repo/scripts/docs-site/check-built-links.mjs"
mk_site() { # mk_site <dir> <extra href for the generated page> <extra href for the passthrough page>
  mkdir -p "$1/page" "$1/guide" || return 1
  printf '<h2 id="sec">S</h2>\n<a href="/Himmel/page/#sec">ok</a> <a href="#sec">ok</a> <a href="https://example.invalid/x">ext</a> %s\n' "$2" >"$1/page/index.html"
  printf '<a href="../page/#sec">ok</a> <a href="../page/">ok</a> %s\n' "$3" >"$1/guide/raw.html"
}
built_ok() { node "$links_chk" "$1" /Himmel >/dev/null 2>&1; }
built_rc1() { node "$links_chk" "$1" /Himmel >/dev/null 2>&1; [ $? -eq 1 ]; }
mk_site "$sweep_ctl/links-clean" "" "" || exit 1
mk_site "$sweep_ctl/links-route" '<a href="/Himmel/no-such/">x</a>' "" || exit 1
mk_site "$sweep_ctl/links-frag" '<a href="/Himmel/page/#gone">x</a>' "" || exit 1
mk_site "$sweep_ctl/links-raw-route" "" '<a href="../setup/vm-mode.md">x</a>' || exit 1
mk_site "$sweep_ctl/links-raw-frag" "" '<a href="../page/#gone">x</a>' || exit 1
mk_site "$sweep_ctl/links-escape" '<a href="/Others/page/#sec">x</a>' "" || exit 1
mk_site "$sweep_ctl/links-pct" '<a href="/Himmel/my%20page/">x</a>' "" || exit 1
mkdir "$sweep_ctl/links-pct/my page" && echo ok >"$sweep_ctl/links-pct/my page/index.html" || exit 1
mk_site "$sweep_ctl/links-data" '<a data-href="/Himmel/no-such/" href="/Himmel/page/">x</a>' "" || exit 1
mk_site "$sweep_ctl/links-sd" "" '<a href="../../links-sd-extra/x/">x</a>' || exit 1
mkdir -p "$sweep_ctl/links-sd-extra/x" && echo ok >"$sweep_ctl/links-sd-extra/x/index.html" || exit 1
mk_site "$sweep_ctl/links-ent" '<a href="/Himmel/page/#a&amp;b">x</a> <a href="#a%26b">y</a>' "" || exit 1
printf '<h2 id="a&amp;b">E</h2>\n' >>"$sweep_ctl/links-ent/page/index.html" || exit 1
mk_site "$sweep_ctl/links-inert" '<!-- <a href="/Himmel/no-such/">x</a> --> <script>var s = '"'"'<a href="/Himmel/no-such/">x</a>'"'"';</script>' "" || exit 1
mk_site "$sweep_ctl/links-case" '<a href="#up">x</a>' "" || exit 1
printf '<h2 ID = "up">U</h2>\n' >>"$sweep_ctl/links-case/page/index.html" || exit 1
mk_site "$sweep_ctl/links-meta" '<a href="#viewport">x</a> <meta name="viewport" content="w">' "" || exit 1
mk_site "$sweep_ctl/links-aname" '<a href="#legacy">x</a> <a name="legacy">L</a>' "" || exit 1
mk_site "$sweep_ctl/links-sid" '<a href="#sid">x</a> <script id="sid">var s = 1;</script>' "" || exit 1
mk_site "$sweep_ctl/links-bare" '<a href=/Himmel/no-such/>x</a>' "" || exit 1
mk_site "$sweep_ctl/links-spaced" '<a href = "/Himmel/no-such/">x</a>' "" || exit 1
mk_site "$sweep_ctl/links-query" '<a href="/Himmel/page/?v=1#sec">x</a> <a href="../page/?v=1">y</a>' "" || exit 1
mk_site "$sweep_ctl/links-proto" '<a href="//example.invalid/x">x</a>' "" || exit 1
mkdir "$sweep_ctl/links-empty" || exit 1
built_rc2() { node "$links_chk" "$1" /Himmel >/dev/null 2>&1; [ $? -eq 2 ]; }
check "built links: a clean fixture site passes" built_ok "$sweep_ctl/links-clean"
check "built links: an entity-escaped fragment and its percent-encoded form resolve" built_ok "$sweep_ctl/links-ent"
check "built links: an anchor inside a comment or script is not a link" built_ok "$sweep_ctl/links-inert"
check "built links: an upper-case ID attribute with spaced equals is a fragment target" built_ok "$sweep_ctl/links-case"
check "built links: a legacy name on an anchor is a fragment target" built_ok "$sweep_ctl/links-aname"
check "built links: the id on a script element is a fragment target" built_ok "$sweep_ctl/links-sid"
check "control: built links fails a fragment that only a meta name carries" built_rc1 "$sweep_ctl/links-meta"
check "control: built links fails a dead unquoted href" built_rc1 "$sweep_ctl/links-bare"
check "control: built links fails a dead href with spaced equals" built_rc1 "$sweep_ctl/links-spaced"
check "built links: a percent-encoded link to a spaced directory resolves" built_ok "$sweep_ctl/links-pct"
check "built links: a data-href attribute is not a link" built_ok "$sweep_ctl/links-data"
check "built links: a query string is not part of the route" built_ok "$sweep_ctl/links-query"
check "built links: a protocol-relative link is external" built_ok "$sweep_ctl/links-proto"
check "control: built links fails a relative link into a sibling directory sharing the dist prefix" built_rc1 "$sweep_ctl/links-sd"
check "control: built links fails a dead generated-page route" built_rc1 "$sweep_ctl/links-route"
check "control: built links fails a dead generated-page fragment" built_rc1 "$sweep_ctl/links-frag"
check "control: built links fails a dead route in a passthrough page" built_rc1 "$sweep_ctl/links-raw-route"
check "control: built links fails a dead fragment in a passthrough page" built_rc1 "$sweep_ctl/links-raw-frag"
check "control: built links fails a root link outside the site base" built_rc1 "$sweep_ctl/links-escape"
check "control: built links exits 2 on a dist with no pages" built_rc2 "$sweep_ctl/links-empty"

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
check "criterion 1: only the permitted docs files are edited" docs_ok "$repo"

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
# the shared page script may only import the vite preload helper statically; the renderer chunks load on demand
page_js=$(grep -o '/_astro/page\.[^"]*\.js' "$(route_of glossary.md)" | head -1)
page_js="$dist${page_js#/Himmel}"
check "control: the page script was found" test -f "$page_js"
check "criterion 4: mermaid loads on demand, not through a static import of the page script" is "$(grep -o 'from"\./[^"]*"' "$page_js" | grep -vc 'preload-helper')" 0
check "criterion 4: the page script imports the renderer behind a diagram check" grep -q 'pre\.mermaid' "$page_js"
check "criterion 4: the diagram theme follows data-theme" grep -q 'dataset\.theme' "$page_js"
check "criterion 4: a data-theme change re-renders the diagrams" grep -q 'MutationObserver' "$page_js"
for h in adoption-trail.html guide/installer-journey.html guide/loops-and-graphs.html guide/dev-graph.html guide/dev-graph/dev-graph.js guide/dev-graph/dev-graph.css guide/dev-graph/tokens.css guide/dev-graph/graph.json; do
  check "criterion 4: $h byte-identical" cmp "$repo/docs/$h" "$dist/$h"
done

# --- IA: sidebar groups equal the F1 list and the v5 frame 1 tree, hero Home with the F2 copy and CTA
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
# the built sidebar, one line per group and per entry in it: a group label starts the line, an entry is indented two spaces
sidebar_of() { # sidebar_of <page.html> [<group label>]: with a group, that group's entries only, unindented
  node --input-type=module -e "
import fs from 'node:fs';
const html = fs.readFileSync(process.argv[1], 'utf8');
const want = process.argv[2];
const text = (s) => s.replace(/&amp;/g, '&').replace(/&#39;/g, \"'\").replace(/&quot;/g, '\"');
let depth = 0, group = '', inside = 0;
const out = [];
for (const m of html.slice(html.indexOf('<ul class=\"top-level')).matchAll(/<(\/?)ul\b|<span class=\"large[^\"]*\">([^<]*)<|<a href[^>]*><span[^>]*>([^<]*)</g)) {
  const label = m[2] ?? m[3];
  if (label === undefined) {
    depth += m[1] ? -1 : 1;
    if (inside && depth < inside) inside = 0;
    if (depth === 0) break;
    continue;
  }
  if (want === undefined) {
    if (depth === 1) out.push(text(label));
    else if (depth === 2) out.push('  ' + text(label));
  } else if (inside && depth === inside) out.push(text(label));
  else if (m[2] !== undefined && text(label) === want) inside = depth + 1;
}
process.stdout.write(out.join('\n') + '\n');" "$@"
}
frame1=$(grep -vE '^#|\[pending\]$' "$repo/scripts/docs-site/sidebar-v5-frame1.txt")
got_nav=$(sidebar_of "$(route_of getting-started.md)") || got_nav='<node failed>'
if [ "$got_nav" = "$frame1" ]; then ok "IA v5: the sidebar equals frame 1, pending pages left out"; else
  ko "IA v5: the sidebar equals frame 1, pending pages left out"
  diff <(printf '%s\n' "$frame1") <(printf '%s\n' "$got_nav") | sed 's/^/  /'
fi
check "control: sidebar_of read a sidebar" test "$(printf '%s\n' "$got_nav" | wc -l)" -gt 20
check "control: the frame 1 fixture differs from a sidebar with one entry moved" fails is "$frame1" "$(printf '%s\n' "$frame1" | sed '2{h;d};3G')"
check "IA v5: Plugins lists himmel-guard and handover only" is "$(sidebar_of "$(route_of getting-started.md)" Plugins | paste -sd'|')" "himmel-guard|handover"
check "IA v5: Internals… is collapsed on a page outside it" grep -qE '<details class="[^"]*"><summary class="[^"]*"><span class="group-label[^"]*"><span class="large[^"]*">Internals…<' "$(route_of getting-started.md)"
check "control: an open group does not match the collapsed pattern" fails grep -qE '<details class="[^"]*"><summary class="[^"]*"><span class="group-label[^"]*"><span class="large[^"]*">Get started<' "$(route_of getting-started.md)"
for r in setup/new-machine launchers setup/codex setup/cli-proxy-lane hermes-runbook setup/cloud-environment jarvis-subsystems himmel-bus voice orchestration-patterns security/npm-policy security/python-policy tool-adoption/rubric tool-adoption/registry tool-adoption/telemetry tool-adoption/lane-adoption-playbook; do
  check "IA v5: /$r/, moved under Internals…, still resolves at its old URL" test -f "$dist/$r/index.html"
done
home="$dist/index.html"
check "IA: Home is the hero page with the v5 F2 headline" grep -qF 'Ship more with Claude Code, and keep every change reviewable.' "$home"
check "IA: Home no longer carries the v4 headline" absent 'Let Claude Code work on its own' "$home"
proof_item() { # proof_item <html> <title>: print the list item that opens with the bold <title>.
  node -e "const t = process.argv[2].replace(/[.*+?^\${}()|[\]\\\\]/g, '\\\\$&'); const m = require('fs').readFileSync(process.argv[1], 'utf8').match(new RegExp('<li><strong>' + t + '\\\\.</strong>[\\\\s\\\\S]*?</li>')); if (!m) process.exit(2); process.stdout.write(m[0]);" "$1" "$2"
}
proof_has() { # proof_has <html> <title> <tag>: that proof's own list item carries <tag>
  local p
  p=$(proof_item "$1" "$2") || return 1
  case "$p" in *"$3"*) ;; *) return 1 ;; esac
}
printf '<li><strong>One road for every change.</strong> x</li>\n<li><strong>Next.</strong> y<br><em><a href="/Himmel/adoption-trail.html">How a change ships</a></em></li>' >"$ctl/proof-untagged"
check "control: proof_has fails a proof whose tag sits in another item" fails proof_has "$ctl/proof-untagged" 'One road for every change' '<em><a href="/Himmel/adoption-trail.html">How a change ships</a></em>'
check "control: proof_has passes the tag in its own item" proof_has "$ctl/proof-untagged" 'Next' '<em><a href="/Himmel/adoption-trail.html">How a change ships</a></em>'
check "IA: Home proof 1 with its How a change ships tag" proof_has "$home" 'One road for every change' '<em><a href="/Himmel/adoption-trail.html">How a change ships</a></em>'
check "IA: Home proof 2 with its reach tag" proof_has "$home" 'Guardrails that hold' '<em>Level 1 · in your project</em>'
check "IA: Home proof 3 with its reach tag" proof_has "$home" 'Cost you can see' '<em>Level 5</em>'
review_proof_clean() { # review_proof_clean <html>: the One road list item exists and never says "in your project"
  local p
  p=$(proof_item "$1" 'One road for every change') || return 1
  case "$p" in *'in your project'*) return 1 ;; esac
}
printf '<li><strong>One road for every change.</strong> x<br><em>Level 1 · in your project</em></li>' >"$ctl/proof-claim"
check "control: review_proof_clean fails a review proof that claims in your project" fails review_proof_clean "$ctl/proof-claim"
check "control: review_proof_clean fails a page with no review proof" fails review_proof_clean "$ctl/page"
check "IA: the review proof never claims it runs in your project" review_proof_clean "$home"
check "IA: Home leaves out the measured line" absent '2,000 pull requests' "$home"
check "IA: Home primary CTA is Quickstart" grep -qE 'sl-link-button[^>]* primary [^>]*href="getting-started/">Quickstart' "$home"
check "IA: Home secondary CTA is How a change ships" grep -qE 'sl-link-button[^>]* minimal [^>]*href="adoption-trail\.html">How a change ships' "$home"
check "IA: Home has exactly one h1" is "$(grep -o '<h1' "$home" | wc -l | tr -d ' ')" 1
check "IA: the docs map is still built" test -f "$dist/docs-map/index.html"

# --- built links: every local route and fragment in the built site (passthrough guides included) resolves
check "built links: every local route and #fragment in dist resolves" built_ok "$dist"

# --- J1: full site (one page per IA section, trail page, raw passthrough, search)
for r in daily-loop handover/afk-mode glossary internals/stuck-playbook contributing; do
  check "J1: IA page /$r/ built" test -f "$dist/$r/index.html"
done
check "J1: /adoption-trail.html served" test -f "$dist/adoption-trail.html"
check "J1: /guide/dev-graph.html served" test -f "$dist/guide/dev-graph.html"
check "J1: /guide/dev-graph.html is the development graph page" grep -qF '<title>Development graph</title>' "$dist/guide/dev-graph.html"
check "J1: the sidebar lists the development graph" grep -q 'href="/Himmel/guide/dev-graph"' "$(route_of getting-started.md)"
check "J1: the sidebar's extensionless dev-graph path redirects to the page" grep -q 'guide/dev-graph\.html' "$dist/guide/dev-graph/index.html"
for raw in setup/install.md setup/settings-template.json setup/profiles/operator.install-profile.json; do
  check "J1: raw $raw byte-identical" cmp "$repo/docs/$raw" "$dist/$raw"
done
c_raw=1
while IFS= read -r f; do
  cmp -s "$repo/docs/$f" "$dist/$f" || { c_raw=0; echo "  raw copy differs: $f"; }
done <<<"$allow"
if [ "$c_raw" -eq 1 ]; then ok "J1: every allowlisted .md is served raw at its path"; else ko "J1: every allowlisted .md is served raw at its path"; fi
check "J1: Pagefind index built" test -f "$dist/pagefind/pagefind.js"
hit=$(pf_hit "$dist")
hit_rc=$?
if hit_ok "$hit_rc" "$hit"; then ok "J1: Pagefind hit for 'stuck playbook' ($hit)"; else ko "J1: Pagefind hit for 'stuck playbook' (exit $hit_rc, got: $hit)"; fi

rm -f "$here/.build.log"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
