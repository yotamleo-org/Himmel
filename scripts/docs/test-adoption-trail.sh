#!/usr/bin/env bash
# Suite for docs/adoption-trail.html, the level data file it is built from, and
# the Pages docs that point at it.
#
# The trail is a static page served by GitHub Pages, built by
# site/src/trail/render.mjs from site/src/trail/levels.json. Nothing else loads
# it in CI: a dead href, a component whose detail only a script shows, or a
# claim that drifted from the tree ships silently. Every case is mechanical and
# derives its expected value from the tree, not from a number typed into the
# test: the cadence rows come from cadence-registry.json and the plugin ids
# from plugin-profiles.json, so adding a registry row without touching the
# data file fails here.
#
#   1. SYNC     — the page is exactly what render.mjs builds from the data file.
#   2. NOJS     — with every script removed, each level is a <details id="lvl-N">
#                 and each component's detail text sits inside its own
#                 <details>; a copy missing its first component block fails.
#   3. LINKS    — every relative href/src resolves: a file under docs/, or a site
#                 route whose page is in site/allowlist.txt; every #fragment is
#                 an id on the page.
#   4. PAGES    — no "once Pages is enabled" phrasing survives (Pages is live),
#                 and docs/README.md documents how the site is served.
#   5. CURRENCY — the cadences shown plus the ones left out are exactly the
#                 registry rows, the page shows the shown ones and their count,
#                 every plugin id is in the catalog, the manifest count matches,
#                 and the claims that drifted before stay fixed.
#   6. NO THIRD-PARTY REQUEST — the page loads nothing from another host.
#   7. FIRST PROTECTED PROJECT — the install is committed before the first
#                 worktree, the undo and the ticket opt-out are named, and no
#                 first-run page promises an unmeasured time.
#   8. WIDTH    — at 360 px the document does not scroll sideways (a headless
#                 Chromium measurement when one is installed), and the CSS lets
#                 only code scroll inside its own box.
#
# Platform guard (gitbash-only): POSIX bash 3.2+ plus grep/sed/jq/perl/python3
# and node, so it runs unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/test-adoption-trail.sh [--registry <cadence-registry.json>]
#        (--registry checks the data file against another registry, such as an
#        edited copy, to show the CURRENCY case fails on a new row)
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PAGE="$ROOT/docs/adoption-trail.html"
DATA="$ROOT/site/src/trail/levels.json"
RENDER="$ROOT/site/src/trail/render.mjs"
DOCS_README="$ROOT/docs/README.md"
REGISTRY="$ROOT/scripts/himmelctl/lib/cadence-registry.json"
CATALOG="$ROOT/scripts/lanes/plugin-profiles.json"
MANIFEST="$ROOT/scripts/install/manifest.json"
ALLOW="$ROOT/site/allowlist.txt"

if [ "${1:-}" = "--registry" ]; then
  REGISTRY="${2:?--registry needs a path}"
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

[ -f "$PAGE" ] || { echo "FAIL: $PAGE missing" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/adoption-trail.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

have_data=1
if [ -f "$DATA" ] && jq -e '.levels | length > 0' "$DATA" >/dev/null 2>&1; then
  ok "the level data file exists and lists levels"
else
  have_data=0
  bad "site/src/trail/levels.json must exist and list the trail's levels"
fi

# --- 1. SYNC ------------------------------------------------------------------

if [ "$have_data" = 1 ] && [ -f "$RENDER" ] && sync_out="$(node "$RENDER" --check 2>&1)"; then
  ok "docs/adoption-trail.html is what render.mjs builds from levels.json"
else
  bad "docs/adoption-trail.html differs from the render of levels.json (run: node site/src/trail/render.mjs)" "${sync_out:-render.mjs or levels.json missing}"
fi

# --- 2. NOJS ------------------------------------------------------------------

# Prints one line per level or component whose text a reader without JavaScript
# would not see (empty = all present).
nojs_missing() {
  python3 -I - "$1" "$2" <<'PY'
import html, json, re, sys
page = open(sys.argv[1], encoding="utf-8").read()
data = json.load(open(sys.argv[2], encoding="utf-8"))
page = re.sub(r"<!--.*?-->", "", page, flags=re.S)
page = re.sub(r"<(script|style|template)\b.*?</\1\s*>", "", page, flags=re.S | re.I)
def text(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip()
blocks = [text(b) for b in re.findall(r'<details class="comp"[^>]*>(.*?)</details>', page, flags=re.S)]
for lvl in data["levels"]:
    if not re.search(r'<details\b[^>]*\bid="lvl-%d"' % lvl["n"], page):
        print("level %d is not a <details id=\"lvl-%d\">" % (lvl["n"], lvl["n"]))
    for c in lvl.get("components", []):
        name, detail = text(c["name"]), text(c["detail"])
        if not any(b.startswith(name) and detail in b for b in blocks):
            print("level %d component %r: detail not in a <details> block" % (lvl["n"], name))
PY
}

if [ "$have_data" = 1 ]; then
  n_comp="$(jq '[.levels[].components[]?] | length' "$DATA")"
  missing="$(nojs_missing "$PAGE" "$DATA")"
  if [ "$n_comp" -gt 0 ] && [ -z "$missing" ]; then
    ok "without JavaScript every level is a <details> and all $n_comp component details are in the page"
  else
    bad "text a reader without JavaScript cannot see (components in data: $n_comp)" "$(printf '%s\n' "$missing" | head -5)"
  fi
  python3 -I -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); print(re.sub(r"<details class=\"comp\".*?</details>", "", t, count=1, flags=re.S), end="")' "$PAGE" > "$tmp/nojs.html"
  if [ -n "$(nojs_missing "$tmp/nojs.html" "$DATA")" ]; then
    ok "control: the page without its first component block is reported"
  else
    bad "control: the NOJS check accepted a page missing a component block"
  fi
fi

# --- 3. LINKS -----------------------------------------------------------------

dead=""
while IFS= read -r ref; do
  case "$ref" in
    http://*|https://*|mailto:*|data:*) continue ;;
    '#'*)
      grep -q -F "id=\"${ref#\#}\"" "$PAGE" || dead="$dead $ref"
      continue ;;
  esac
  path="${ref%%#*}"
  case "$path" in
    */)
      route="${path%/}"
      grep -q -x -F -e "$route.md" -e "$route/README.md" "$ALLOW" || dead="$dead $ref" ;;
    *)
      [ -e "$ROOT/docs/$path" ] || dead="$dead $ref" ;;
  esac
done < <(perl -0777 -pe 's/<script\b.*?<\/script>//gs' "$PAGE" | grep -o -E '(href|src)="[^"]+"' | sed -E 's/^(href|src)="//; s/"$//' | sort -u)
if [ -z "$dead" ]; then ok "every relative href/src resolves to a docs file, a built site route or an id on the page"; else bad "dead relative links" "$dead"; fi

# --- 4. PAGES -----------------------------------------------------------------

stale_pages='once (GitHub )?Pages is enabled|until then, open it from your clone'
for f in "$PAGE" "$DOCS_README"; do
  if grep -q -i -E "$stale_pages" "$f"; then
    bad "not-yet-live Pages phrasing in ${f#"$ROOT"/}" "$(grep -n -i -E "$stale_pages" "$f" | head -3)"
  else
    ok "no not-yet-live Pages phrasing in ${f#"$ROOT"/}"
  fi
done

# shellcheck disable=SC2016  # the backticks are literal markdown in the pattern
if grep -q -E 'http\.server' "$DOCS_README" && grep -q -E '\.nojekyll' "$DOCS_README" \
   && grep -q -F 'pages.yml' "$DOCS_README" && grep -q -F '`docs/**`' "$DOCS_README"; then
  ok "docs/README.md documents the Pages source, static serving and local preview"
else
  bad "docs/README.md must name the Pages source (pages.yml on docs/**), .nojekyll and a local preview (http.server)"
fi

# --- 5. CURRENCY ----------------------------------------------------------------

if [ "$have_data" = 1 ]; then
  reg_ids="$(jq -r '.cadences[].id' "$REGISTRY" | sort)"
  shown_ids="$(jq -r '.cadences.shown[].id' "$DATA" | sort)"
  out_ids="$(jq -r '.cadences.left_out[].id' "$DATA" | sort)"
  both="$(comm -12 <(printf '%s\n' "$shown_ids") <(printf '%s\n' "$out_ids") | tr '\n' ' ')"
  union="$(printf '%s\n%s\n' "$shown_ids" "$out_ids" | grep -v '^$' | sort)"
  if [ -n "$both" ]; then
    bad "cadences both shown and left out in levels.json" "$both"
  elif [ "$union" = "$reg_ids" ]; then
    ok "levels.json shows or leaves out each of the $(printf '%s\n' "$reg_ids" | grep -c .) registry cadences, once"
  else
    bad "levels.json cadences (shown + left out) differ from the registry" "only in registry: $(comm -23 <(printf '%s\n' "$reg_ids") <(printf '%s\n' "$union") | tr '\n' ' ')  only in levels.json: $(comm -13 <(printf '%s\n' "$reg_ids") <(printf '%s\n' "$union") | tr '\n' ' ')"
  fi

  no_why="$(jq -r '.cadences.left_out[] | select((.why // "") | length == 0) | .id' "$DATA" | tr '\n' ' ')"
  if [ -z "$no_why" ]; then ok "every left-out cadence says why"; else bad "left-out cadences with no reason" "$no_why"; fi

  win_shown=""
  for id in $shown_ids; do
    req="$(jq -r --arg id "$id" '.cadences[] | select(.id == $id) | .requires' "$REGISTRY")"
    case "$req" in platform:windows) win_shown="$win_shown $id" ;; esac
  done
  if [ -z "$win_shown" ]; then ok "no shown cadence needs a dropped platform"; else bad "shown cadences that need platform:windows" "$win_shown"; fi

  n_shown="$(printf '%s\n' "$shown_ids" | grep -c .)"
  table="$(sed -n '/<table class="cadtbl">/,/<\/table>/p' "$PAGE")"
  rows="$(printf '%s\n' "$table" | grep -o -E '<tr><td><code>[a-z-]+</code></td>' | sed -E 's/.*<code>([a-z-]+)<\/code>.*/\1/' | sort)"
  if [ "$rows" = "$shown_ids" ]; then ok "the page's cadence table lists exactly the $n_shown shown cadences"; else bad "the page's cadence table rows differ from levels.json's shown cadences" "page: $(printf '%s' "$rows" | tr '\n' ' ')"; fi
  if grep -q -F "Scheduled jobs: pick from $n_shown<" "$PAGE"; then ok "the cadence count on the page ($n_shown) = shown cadences"; else bad "the page must say 'Scheduled jobs: pick from $n_shown'"; fi

  bad_plugins=""
  for p in $(jq -r '[.levels[].components[]?.plugin // empty] | unique[]' "$DATA"); do
    jq -e --arg p "$p" '.catalog | index($p) != null' "$CATALOG" >/dev/null || bad_plugins="$bad_plugins $p"
  done
  n_plugins="$(jq '[.levels[].components[]?.plugin // empty] | unique | length' "$DATA")"
  if [ "$n_plugins" -gt 0 ] && [ -z "$bad_plugins" ]; then ok "all $n_plugins plugin ids in levels.json are in the plugin-profiles.json catalog"; else bad "plugin ids in levels.json not in the plugin-profiles.json catalog (named: $n_plugins)" "$bad_plugins"; fi

  bad_status="$(jq -r '.levels[].components[]? | select(.status | IN("shipped","beta","roadmap") | not) | .name' "$DATA" | tr '\n' ' ')"
  if [ -z "$bad_status" ]; then ok "every component status is shipped, beta or roadmap"; else bad "components with an unknown status" "$bad_status"; fi
fi

all_n="$(jq '.items | length' "$MANIFEST")"
page_items="$(grep -o -E 'install manifest, [0-9]+ items' "$PAGE" | grep -o -E '[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$page_items" = "$all_n" ]; then ok "manifest count on the page ($page_items) = scripts/install/manifest.json ($all_n)"; else bad "the page's install-manifest count is '$page_items', the manifest has $all_n items"; fi

if grep -q -i -E 'ollama|copilot' "$PAGE"; then
  bad "the wizard's lanes menu is codex + hermes only; page still mentions ollama/copilot" "$(grep -n -i -E 'ollama|copilot' "$PAGE" | head -3)"
else
  ok "page does not offer ollama/copilot as wizard lanes"
fi

if grep -q -E "fork of AgriciDaniel" "$PAGE"; then
  bad "claude-obsidian is upstream-pinned (fork retired), page still says fork"
else
  ok "claude-obsidian is not described as a himmel fork"
fi

if grep -q -E '<b>lane</b>|Parallel lanes' "$PAGE"; then
  bad "Level 7 defines 'lane' as a work session; docs/glossary.md calls that a leg" "$(grep -n -E '<b>lane</b>|Parallel lanes' "$PAGE" | head -3)"
else
  ok "Level 7 uses the glossary's words for a work session"
fi

# adopt.sh's install_precommit_hooks runs for every profile, so the git gates
# are not roadmap work.
gates_roadmap='rm-gates|Gates for every profile|roadmap gates item|arrive with the developer setup'
if grep -q -i -E "$gates_roadmap" "$PAGE"; then
  bad "the commit/push gates install for every profile (adopt.sh install_precommit_hooks); the page still lists them as roadmap" "$(grep -n -i -E "$gates_roadmap" "$PAGE" | head -3)"
else
  ok "the git gates are not listed as roadmap work"
fi

# No internal ticket key in reader-facing text. A comment or an attribute is
# fine; strip both (non-greedy, whole file) before checking.
reader_text="$(perl -0777 -pe 's/<!--.*?-->//gs; s/<script\b.*?<\/script>//gs; s/<style\b.*?<\/style>//gs' "$PAGE" | sed -E 's/<[a-zA-Z][^>]*>//g')"
ticket_hits="$(printf '%s' "$reader_text" | grep -o -E 'HIMMEL-[0-9]+' | sort -u | tr '\n' ' ')"
if [ -z "$ticket_hits" ]; then
  ok "no internal ticket key in reader-facing text"
else
  bad "internal ticket key(s) in reader-facing text" "$ticket_hits"
fi

# The control question (what will it do, how do I undo it) is answered before
# the reader meets the first command that installs.
ctl_line="$(grep -n -m1 -F 'Who is in control?' "$PAGE" | cut -d: -f1)"
install_cmd_line="$(grep -n -m1 -E 'adopt\.sh --profile|himmelctl/bin\.js install' "$PAGE" | cut -d: -f1)"
if [ -n "$ctl_line" ] && [ -n "$install_cmd_line" ] && [ "$ctl_line" -lt "$install_cmd_line" ]; then
  ok "who is in control (and how to undo) is answered above the first install command"
else
  bad "the control question must come before the first install command" "control=line ${ctl_line:-none}, first install command=line ${install_cmd_line:-none}"
fi

# --- 6. NO THIRD-PARTY REQUEST ---------------------------------------------------

# Opening the page must not contact any other host: a stylesheet, script, font,
# image, media or object on an external origin discloses the visit. Anchor hrefs
# are navigation, not loads, so they are not checked.
find_ext_loads() {
  perl -0777 -ne '
    while (/<([a-z][a-z0-9:-]*)\b((?:[^>"\x27]|"[^"]*"|\x27[^\x27]*\x27)*)>/gi) {
      my ($tag, $attrs, $markup) = (lc($1), $2, $&);
      while ($attrs =~ /([^\s=\/>]+)\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s>]+))/g) {
        my ($attr, $value) = (lc($1), $2 // $3 // $4);
        next unless $attr =~ /^(?:src|poster|data|srcset)$/ || ($tag eq "link" && $attr eq "href");
        my @urls = $attr eq "srcset" ? split(/,/, $value) : ($value);
        if (grep { /^\s*(?:https?:|\/\/)/i } @urls) {
          print "$markup\n";
          last;
        }
      }
    }
    print "$&\n" while /\burl\(\s*["\x27]?(?:https?:)?\/\/[^)]*\)|\@import\s+(?:url\()?["\x27]?(?:https?:)?\/\/[^;]*/gi;
  ' | cut -c1-120
}
# Positive controls: each attribute quoting form must be caught, so the scan
# cannot go blind to a form the real page does not currently use.
ctl_missed=""
for ctl in '<link rel="stylesheet" href="https://x.example/a.css">' \
           "<script src='https://x.example/a.js'></script>" \
           '<img src=https://x.example/a.png>' \
           '<img/src="https://x.example/a.png">' \
           '<video preload=""poster="https://x.example/a.png"></video>' \
           '<img srcset="/a.png 1x, https://x.example/b.png 2x">' \
           '<video src="https://x.example/a.mp4"></video>' \
           "<video poster='//x.example/a.png'></video>" \
           '<audio src=http://x.example/a.mp3></audio>' \
           '<video><source src="//x.example/a.mp4"></video>' \
           '<audio><source src="https://x.example/a.mp3"></audio>' \
           '<object data="https://x.example/a.pdf"></object>' \
           '<video srcset="/a.png 320w, /b.png 640w, //x.example/c.png 960w"></video>' \
           '<style>@import url(//x.example/a.css);</style>'; do
  [ -n "$(printf '%s' "$ctl" | find_ext_loads)" ] || ctl_missed="$ctl_missed $ctl"
done
if [ -n "$ctl_missed" ]; then
  bad "the third-party-request scan missed a control form" "$ctl_missed"
else
  ok "the third-party-request scan catches every external resource control"
fi
ctl_false_hits=""
for ctl in '<img srcset="/a.png 1x, /b.png 2x">' \
           '<a href="https://x.example/">external navigation</a>' \
           '<img data-src="https://x.example/a.png" src="/a.png">' \
           "<img title=' src=\"https://x.example/a.png\"' src='/a.png'>"; do
  [ -z "$(printf '%s' "$ctl" | find_ext_loads)" ] || ctl_false_hits="$ctl_false_hits $ctl"
done
if [ -n "$ctl_false_hits" ]; then
  bad "the third-party-request scan flagged a non-loading control" "$ctl_false_hits"
else
  ok "local-only srcset and external anchor href are not third-party loads"
fi
ext_loads="$(find_ext_loads <"$PAGE")"
if [ -z "$ext_loads" ]; then
  ok "the page loads no stylesheet, script, font or image from an external host"
else
  bad "the page requests a third-party resource when opened (fonts.googleapis.com, gstatic, a CDN)" "$ext_loads"
fi

# --- 7. FIRST PROTECTED PROJECT ----------------------------------------------
# The quickstart, the trial and the install guide are one sequence. On a clean
# machine the install leaves its files untracked, so a worktree cut before the
# install is committed lacks the hooks and the edit guard.
GS="$ROOT/docs/getting-started.md"
INST="$ROOT/docs/setup/install.md"

core_n="$(jq '[.items[] | select(.profiles | index("core"))] | length' "$MANIFEST")"
if grep -q -E "\b${core_n} items\b" "$INST" && grep -q -E "all.{0,2} \(${all_n} items\)" "$INST"; then
  ok "install.md profile counts match the manifest (core ${core_n}, all ${all_n})"
else
  bad "install.md profile counts drifted from scripts/install/manifest.json (core ${core_n}, all ${all_n})"
fi

# first line number of a pattern in a file, empty when absent
line_of() { grep -n -E -m1 -e "$1" "$2" | cut -d: -f1; }
k="$(line_of 'git commit -m "chore: install himmel' "$GS")"
c="$(line_of 'git merge --ff-only' "$GS")"
w="$(line_of 'scripts/worktree\.sh feat/try-himmel' "$GS")"
if [ -n "$k" ] && [ -n "$c" ] && [ -n "$w" ] && [ "$k" -lt "$c" ] && [ "$c" -lt "$w" ]; then
  ok "getting-started.md commits and merges the install before it creates the worktree"
else
  bad "getting-started.md must commit, merge, then create the worktree (commit line '${k:-none}', merge line '${c:-none}', worktree line '${w:-none}')"
fi
k="$(line_of 'adopt\.sh --scope project --target [^ ]+ --commit-install' "$PAGE")"
w="$(line_of 'bash scripts/worktree\.sh feat/try-himmel' "$PAGE")"
if [ -n "$k" ] && [ -n "$w" ] && [ "$k" -lt "$w" ]; then
  ok "adoption-trail.html commits the install (--commit-install) before it creates the worktree"
else
  bad "adoption-trail.html must commit the install with --commit-install, then create the worktree (commit line '${k:-none}', worktree line '${w:-none}')"
fi

for pg in "$GS" "$INST" "$PAGE"; do
  name="$(basename "$pg")"
  if grep -q -E 'uninstall --yes' "$pg"; then
    ok "$name gives the non-interactive undo as uninstall --yes"
  else
    bad "$name never shows uninstall --yes (a bare uninstall aborts without a terminal)"
  fi
  if grep -q -E 'TICKET_ID_REQUIRED=0' "$pg"; then
    ok "$name states the ticket-reference prerequisite and its opt-out"
  else
    bad "$name never says the installed commit gate wants a ticket reference (or TICKET_ID_REQUIRED=0)"
  fi
done

time_re='≈ ?[0-9]+ ?min|about (\*\*)?15 minutes|~15 minutes|in about 15 minutes|15-minute walkthrough|First 5 minutes|first 5 minutes|[Ff]ive-minute'
if ! printf 'about **15 minutes\n' | grep -q -E "$time_re"; then
  bad "the time-promise matcher no longer matches its own positive control"
fi
if ! printf 'The setup takes about 15 minutes\n' | grep -q -E "$time_re"; then
  bad "the time-promise matcher misses a plain-text about 15 minutes promise"
fi
time_files=("$GS" "$PAGE")
[ -f "$DATA" ] && time_files+=("$DATA")
promised="$(grep -n -E "$time_re" "${time_files[@]}")" && grep_rc=0 || grep_rc=$?
if [ "$grep_rc" -gt 1 ]; then
  bad "grep failed (rc=$grep_rc) while scanning for time promises"
elif [ "$grep_rc" -eq 0 ]; then
  bad "unmeasured time promises on first-run pages" "$(printf '%s\n' "$promised" | cut -c1-110)"
else
  ok "no first-run page promises an unmeasured elapsed time"
fi

# --- 8. WIDTH -------------------------------------------------------------------
# Only code may scroll sideways, inside its own box; the page must not hide a
# too-wide document by clipping it either.
css="$(perl -0777 -ne 'print $1 while /<style\b[^>]*>(.*?)<\/style>/gs' "$PAGE")"
if printf '%s' "$css" | grep -q -E 'pre[^{]*\{[^}]*overflow-x:[[:space:]]*auto' \
   && ! printf '%s' "$css" | grep -q -E '(^|[},])[[:space:]]*(html|body)[[:space:]]*(,[^{]*)?\{[^}]*overflow(-x)?:[[:space:]]*(hidden|clip)'; then
  ok "the CSS scrolls code inside its box and does not clip the document"
else
  bad "the CSS must give pre overflow-x:auto and must not set overflow hidden/clip on html or body"
fi

chrome=""
for b in chromium chromium-browser google-chrome-stable google-chrome; do
  command -v "$b" >/dev/null 2>&1 && { chrome="$b"; break; }
done
if [ -z "$chrome" ]; then
  echo "SKIP 360 px measurement: no headless Chromium on PATH (the CSS assertion above still ran)"
else
  # Chromium's headless window is never narrower than 500 px, so the page is
  # measured inside a 360 px iframe. Every <details> is opened first, so a
  # closed card cannot hide a too-wide line.
  printf '%s\n' '<!doctype html><html><body><iframe id="f" src="w.html" style="width:360px;height:800px;border:0"></iframe><script>' \
    'f.addEventListener("load",()=>{const d=f.contentDocument;for(const x of d.querySelectorAll("details"))x.open=true;document.body.setAttribute("data-sw",d.documentElement.scrollWidth+"/"+d.documentElement.clientWidth)})' \
    '</script></body></html>' > "$tmp/wrap.html"
  for mode in js nojs; do
    if [ "$mode" = nojs ]; then
      perl -0777 -pe 's/<script\b.*?<\/script>//gs' "$PAGE" > "$tmp/w.html"
    else
      cp "$PAGE" "$tmp/w.html"
    fi
    sw="$(timeout 60 "$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$tmp/chrome" --virtual-time-budget=3000 --dump-dom "file://$tmp/wrap.html" 2>/dev/null | grep -o -E 'data-sw="[0-9]+/[0-9]+"' | grep -o -E '[0-9]+/[0-9]+')"
    if [ -z "$sw" ]; then
      bad "360 px ($mode): the headless measurement returned nothing"
    elif [ "${sw%/*}" -le "${sw#*/}" ]; then
      ok "360 px ($mode): no document-level horizontal scroll (scrollWidth/clientWidth $sw)"
    else
      bad "360 px ($mode): the document scrolls sideways (scrollWidth/clientWidth $sw)"
    fi
  done
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
