#!/usr/bin/env bash
# Suite for the designed guide pages under docs/guide/.
#
# The guides are static pages GitHub Pages serves as-is, so nothing else loads
# them in CI. They explain what each setting changes, which only helps while
# every setting they name is real: a renamed or invented key would ship a page
# that teaches a setting nothing reads. Every case derives its expected value
# from the tree.
#
#   1. PARSE    — the page is well-formed: every non-void tag closes in order.
#   2. KEYS     — every setting key the page names (any UPPER_SNAKE token, and
#                 every data-key attribute) is in the config spec
#                 (docs/internals/config-layers.md when present,
#                 docs/configuration.md, .env.example) or the code inventory
#                 (a whole-word match under scripts/).
#   3. CADENCES — every data-cadence id is a row of cadence-registry.json.
#   4. SELF     — the page loads nothing from the network, every relative
#                 href resolves, and no ticket ID appears outside a comment.
#   5. CONTROL  — a fixture page naming a made-up key fails case 2, so the key
#                 check cannot pass vacuously.
#   6. STEPS    — installer-journey.html lists the wizard's questions in the
#                 order scripts/himmelctl/bin.js askQuestions() asks them; a
#                 fixture page with a renamed step fails, so it cannot pass
#                 vacuously.
#   7. TRAIL    — docs/adoption-trail.html carries no claim for a dropped
#                 platform or plugin (.ps1, WSL, Git Bash, superpowers, "the
#                 eight"); a fixture with one fails.
#
# Platform guard (gitbash-only): POSIX bash 3.2+ plus grep/sed/jq/python3, so
# it runs unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/test-site-guides.sh [page.html ...]
#        (no argument = every docs/guide/*.html page)
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REGISTRY="$ROOT/scripts/himmelctl/lib/cadence-registry.json"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

# Prints the page with every <!-- comment --> removed, so the source citations
# beside each section never count as page text.
strip_comments() {
  python3 -I -c 'import re,sys; sys.stdout.write(re.sub(r"<!--.*?-->", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S))' "$1"
}

# Exit 0 when the page's tags nest and close; prints the first fault otherwise.
check_parse() {
  python3 -I - "$1" <<'PY'
import sys
from html.parser import HTMLParser
VOID = {"area","base","br","col","embed","hr","img","input","link","meta","source","track","wbr"}
class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.err = [], None
    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append((tag, self.getpos()[0]))
    def handle_startendtag(self, tag, attrs):
        pass
    def handle_endtag(self, tag):
        if tag in VOID or self.err:
            return
        if not self.stack or self.stack[-1][0] != tag:
            want = self.stack[-1] if self.stack else ("nothing", 0)
            self.err = "line %d: </%s> closes <%s> from line %d" % (self.getpos()[0], tag, want[0], want[1])
            return
        self.stack.pop()
p = P()
p.feed(open(sys.argv[1], encoding="utf-8").read())
p.close()
if p.err:
    print(p.err); sys.exit(1)
if p.stack:
    print("unclosed <%s> from line %d" % p.stack[-1]); sys.exit(1)
PY
}

# Exit 0 when KEY is in the config spec or the code inventory. This file is
# excluded: it names the CONTROL's made-up key, which would otherwise match.
key_known() {
  local key="$1" f
  for f in "$ROOT/docs/internals/config-layers.md" "$ROOT/docs/configuration.md" "$ROOT/.env.example"; do
    [ -f "$f" ] && grep -q -w -F -- "$key" "$f" && return 0
  done
  grep -r -q -w -F --exclude=test-site-guides.sh -- "$key" "$ROOT/scripts" 2>/dev/null
}

# Prints every setting key the page names, one per line.
page_keys() {
  local text
  text="$(strip_comments "$1")"
  {
    printf '%s\n' "$text" | grep -o -E '\b[A-Z][A-Z0-9]*(_[A-Z0-9]+)+\b'
    printf '%s\n' "$text" | grep -o -E 'data-key="[^"]+"' | sed -E 's/^data-key="//; s/"$//'
  } | sort -u
}

# Prints the unknown keys of a page (empty = all known).
unknown_keys() {
  local k out=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    key_known "$k" || out="$out $k"
  done < <(page_keys "$1")
  printf '%s' "$out"
}

BIN="$ROOT/scripts/himmelctl/bin.js"
TRAIL="$ROOT/docs/adoption-trail.html"
TRAIL_STALE='\.ps1|WSL|Git Bash|superpowers|the eight'

# Prints the guide's question ids (kind: 'ask'), in page order, space-joined.
guide_steps() {
  python3 -I -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); print(" ".join(m.group(1) for m in re.finditer(r"\{ id: \x27([a-z]+)\x27[^\n]*?kind: \x27ask\x27", t)))' "$1"
}

# Prints the guide ids of the questions askQuestions() asks, in call order.
wizard_steps() {
  python3 -I - "$BIN" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
a = t.index("async function askQuestions(")
body = t[a:t.index("// All-default answers", a)]
calls = [
    ("profile", r"askNumberedEnum\(ask, 'profile'"),
    ("scope", r"askNumberedEnum\(ask, 'scope'"),
    ("vault", r"askNumberedEnum\(ask, 'vault'"),
    ("handover", r"askNumberedEnum\(ask, 'handover'"),
    ("lanes", r"askLanes\(ask"),
    ("always", r"askNumberedEnum\(ask, 'always-on machine"),
    ("vm", r"askVm\(ask"),
    ("cadences", r"askCadences\(ask"),
    ("privacy", r"Protected Health Information"),
    ("bridge", r"askNumberedEnum\(ask, 'configure the telegram bridge"),
    ("secrets", r"askNumberedEnum\(ask, 'walk through secrets"),
    ("commit", r"askCommitRules\(ask"),
]
found = sorted((m.start(), k) for k, r in calls for m in [re.search(r, body)] if m)
print(" ".join(k for _, k in found))
PY
}

# Prints the stale claims of a trail page, one per line (empty = clean).
trail_stale() {
  strip_comments "$1" | grep -o -E -- "$TRAIL_STALE"
}

check_page() {
  local page="$1" rel err text unknown dead ref ids id hit want got
  rel="${page#"$ROOT"/}"
  [ -f "$page" ] || { bad "$rel exists"; return; }

  if err="$(check_parse "$page")"; then ok "$rel parses: every tag closes in order"; else bad "$rel does not parse" "$err"; fi

  unknown="$(unknown_keys "$page")"
  if [ -z "$unknown" ]; then ok "$rel names only real setting keys ($(page_keys "$page" | grep -c .) checked)"; else bad "$rel names keys the spec and code do not have" "$unknown"; fi

  ids=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    jq -e --arg id "$id" '.cadences | map(.id) | index($id)' "$REGISTRY" >/dev/null || ids="$ids $id"
  done < <(grep -o -E "data-cadence=\"[^\"]+\"|[{,] c: '[^']+'" "$page" | sed -E "s/^data-cadence=\"//; s/\"\$//; s/^[{,] c: '//; s/'\$//" | sort -u)
  if [ -z "$ids" ]; then ok "$rel cadence ids are registry rows"; else bad "$rel cadence ids missing from the registry" "$ids"; fi

  text="$(strip_comments "$page")"
  hit="$(printf '%s\n' "$text" | grep -i -E '<(script|link|img|iframe)[^>]+(src|href)="(https?:)?//|@import|url\((["'\'']?)(https?:)?//')"
  if [ -n "$hit" ]; then
    bad "$rel loads something from the network"
  else
    ok "$rel is self-contained"
  fi

  dead=""
  while IFS= read -r ref; do
    case "$ref" in http://*|https://*|'#'*|mailto:*|data:*) continue ;; esac
    [ -e "$(dirname "$page")/${ref%%#*}" ] || dead="$dead $ref"
  done < <(printf '%s\n' "$text" | grep -o -E 'href="[^"]+"' | sed -E 's/^href="//; s/"$//' | sort -u)
  if [ -z "$dead" ]; then ok "$rel relative links resolve"; else bad "$rel dead relative links" "$dead"; fi

  hit="$(printf '%s\n' "$text" | grep -o -E '\b(HIMMEL|LUNA|SALUS)-[0-9]+\b' | sort -u | tr '\n' ' ')"
  if [ -n "$hit" ]; then
    bad "$rel shows a ticket ID" "$hit"
  else
    ok "$rel shows no ticket ID"
  fi

  if [ "${page##*/}" = installer-journey.html ]; then
    want="$(wizard_steps)"
    got="$(guide_steps "$page")"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then ok "$rel question steps match the wizard order ($want)"; else bad "$rel question steps differ from bin.js askQuestions()" "wizard: $want / guide: $got"; fi
  fi
}

# --- CONTROL: the key check must fail on a made-up key -------------------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/site-guides.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
printf '<!doctype html>\n<html><body><p>Set <code data-key="HIMMEL_GUIDE_INVENTED_KNOB">HIMMEL_GUIDE_INVENTED_KNOB</code>.</p></body></html>\n' > "$tmp/fixture.html"
if [ -n "$(unknown_keys "$tmp/fixture.html")" ]; then
  ok "control: a made-up key is reported unknown"
else
  bad "control: the key check accepted a made-up key"
fi

# --- CONTROL: the STEPS check must fail on a renamed step ----------------------
if [ -f "$ROOT/docs/guide/installer-journey.html" ]; then
  sed "s/{ id: 'bridge'/{ id: 'dropped'/" "$ROOT/docs/guide/installer-journey.html" > "$tmp/installer-journey.html"
  if [ -n "$(wizard_steps)" ] && [ "$(wizard_steps)" != "$(guide_steps "$tmp/installer-journey.html")" ]; then
    ok "control: a guide with a renamed step differs from the wizard"
  else
    bad "control: the STEPS check accepted a guide with a renamed step"
  fi
fi

# --- TRAIL: no claim for a dropped platform or plugin ---------------------------
printf '<p>Run <span class="mono">adopt.ps1</span> in Git Bash.</p>\n' > "$tmp/trail.html"
if [ -n "$(trail_stale "$tmp/trail.html")" ]; then
  ok "control: a stale claim is reported in a trail fixture"
else
  bad "control: the trail check accepted a stale claim"
fi
if [ ! -f "$TRAIL" ]; then
  bad "docs/adoption-trail.html exists"
elif [ -z "$(trail_stale "$TRAIL")" ]; then
  ok "docs/adoption-trail.html carries no dropped-platform or dropped-plugin claim"
else
  bad "docs/adoption-trail.html carries stale claims" "$(trail_stale "$TRAIL" | sort -u | tr '\n' ' ')"
fi

# --- the pages ----------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  pages=("$@")
else
  pages=()
  for p in "$ROOT"/docs/guide/*.html; do [ -f "$p" ] && pages+=("$p"); done
  [ "${#pages[@]}" -gt 0 ] || bad "docs/guide/ has at least one page"
  for want in loops-and-graphs.html installer-journey.html; do
    [ -f "$ROOT/docs/guide/$want" ] || bad "docs/guide/$want exists"
  done
fi
for p in ${pages[@]+"${pages[@]}"}; do
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  check_page "$p"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
