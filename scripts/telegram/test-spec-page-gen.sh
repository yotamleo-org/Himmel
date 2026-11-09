#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # cond && pass || fail: pass and fail always return 0; the md fixture holds literal backticks
# Tests for scripts/telegram/spec-page-gen.py, the one shared spec page generator.
# Usage: bash scripts/telegram/test-spec-page-gen.sh
# Hermetic: every md and page lives under one temp dir; the marker is read back
# by the real reader in chief-route.ts (checkSignaturePage), run under bun.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$REPO_ROOT/scripts/telegram/spec-page-gen.py"
ROUTE="$REPO_ROOT/scripts/telegram/chief-route.ts"

PASS=0 FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }

command -v python3 >/dev/null 2>&1 && command -v bun >/dev/null 2>&1 || { echo "SKIP: python3 and bun are needed"; exit 0; }
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/spec-page-gen-test.XXXXXX")" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT

gen() { python3 -I "$GEN" "$@" 2>&1; }

# What checkSignaturePage says about a page: it reads the marker, then names the spec's missing critic file.
FIXTURE="$T/read-marker.ts"
printf 'import { checkSignaturePage } from "%s";\ntry { await checkSignaturePage(process.argv[2]); console.log("OK"); } catch (e) { console.log((e as Error).message); }\n' "$ROUTE" > "$FIXTURE"
read_marker() { bun "$FIXTURE" "$1" 2>&1; }

# Every spec that must generate carries the diagram the page now requires.
DIAG='<svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="1" width="8" height="8"/></svg>'
printf -v DSECT '\n## Diagrams\n\n```svg\n%s\n```\n' "$DIAG"
printf '# Plain spec\n\n## Section\n\nSome **bold** text and `code`.\n\n- one\n- two\n%s' "$DSECT" > "$T/plain.md"

echo "== marker =="
out="$(gen "$T/plain.md" "$T/plain.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "the plain spec generates" || fail "the plain spec generates" "$out"
page="$(cat "$T/plain.html" 2>/dev/null)"
has "the page carries the spec-source marker with the md's absolute path" "<meta name=\"spec-source\" content=\"$T/plain.md\">" "$page"
msha="$(sha256sum "$T/plain.md" | cut -d' ' -f1)"; psha="$(sha256sum "$T/plain.html" | cut -d' ' -f1)"
printf '%s\n' "$out" | grep -Fqx "sha256 $msha $T/plain.md" && pass "the generator prints the sha256 line of the md it read" || fail "the generator prints the sha256 line of the md it read" "$out"
printf '%s\n' "$out" | grep -Fqx "sha256 $psha $T/plain.html" && pass "the generator prints the sha256 line of the page it wrote" || fail "the generator prints the sha256 line of the page it wrote" "$out"
lacks "the page does not say Not for signature" "ot for signature" "$page"

echo "== draft status =="
printf -- '---\ntickets: HIMMEL-1\nstatus: DRAFT, no critic has read this. Not for signature.\n---\n\n# Front matter status\n\nBody.\n' > "$T/fmstatus.md"
out="$(gen "$T/fmstatus.md" "$T/fmstatus.html")"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/fmstatus.html" ] && pass "a front matter status holding draft text is refused and writes no page" || fail "a front matter status holding draft text is refused and writes no page" "$out"
has "the refusal names the file and the front matter line" "fmstatus.md:3" "$out"
printf -- '---\ntickets: HIMMEL-1\nstatus: Revision r10. Critic status: the verdict files beside this spec decide.\n---\n\n# Ordinary status\n\nBody.\n%s' "$DSECT" > "$T/okstatus.md"
out="$(gen "$T/okstatus.md" "$T/okstatus.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "an ordinary front matter status generates" || fail "an ordinary front matter status generates" "$out"
page="$(cat "$T/okstatus.html" 2>/dev/null)"
lacks "an ordinary front matter status is left off the page" "Revision r10" "$page"
printf '# Body status\n\nStatus: DRAFT, no critic has read this revision.\n\nBody.\n' > "$T/bodystatus.md"
out="$(gen "$T/bodystatus.md" "$T/bodystatus.html")"; rc=$?
[ "$rc" -ne 0 ] && pass "a Status: line in the body is refused" || fail "a Status: line in the body is refused" "$out"
has "the refusal names the line" "bodystatus.md:3" "$out"
has "the refusal says to generate again, then run the critic" "generate the page again, then run the critic on the md and the new page" "$out"
[ ! -e "$T/bodystatus.html" ] && pass "a refused md writes no page" || fail "a refused md writes no page"
printf '# Body banner\n\nThis revision is not for signature yet.\n' > "$T/banner.md"
out="$(gen "$T/banner.md" "$T/banner.html")"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/banner.html" ] && pass "a body line saying not for signature is refused" || fail "a body line saying not for signature is refused" "$out"
cp "$T/plain.md" "$T/self.md"
out="$(gen "$T/self.md" "$T/self.md")"; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$T/plain.md" "$T/self.md" && pass "an output path equal to the md is refused and the md is untouched" || fail "an output path equal to the md is refused and the md is untouched" "$out"

echo "== newlines and tables =="
printf -- '---\r\ntickets: HIMMEL-7\r\n---\r\n\r\n# Crlf spec\r\n\r\nBody.\r\n%s' "$DSECT" > "$T/crlf.md"
out="$(gen "$T/crlf.md" "$T/crlf.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "a CRLF md generates" || fail "a CRLF md generates" "$out"
has "a CRLF md still gets its metadata bar" "HIMMEL-7" "$(cat "$T/crlf.html" 2>/dev/null)"
printf '%s\n' "$out" | grep -Fqx "sha256 $(sha256sum "$T/crlf.md" | cut -d' ' -f1) $T/crlf.md" && pass "the printed sha256 is of the CRLF bytes as read" || fail "the printed sha256 is of the CRLF bytes as read" "$out"
printf '# Tables\n\n| not a table\nthe next line must stay\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n%s' "$DSECT" > "$T/table.md"
gen "$T/table.md" "$T/table.html" >/dev/null
page="$(cat "$T/table.html" 2>/dev/null)"
has "a pipe line with no separator does not eat the next line" "the next line must stay" "$page"
has "a real table renders" "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>" "$page"

echo "== md without a draft line =="
printf -- '---\ntickets: HIMMEL-1\n---\n\n# Spec with front matter\n\nBody.\n%s' "$DSECT" > "$T/fm.md"
out="$(gen "$T/fm.md" "$T/fm.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "an md carrying no status line generates" || fail "an md carrying no status line generates" "$out"
(cd "$T" && gen plain.md rel.html >/dev/null); has "a relative md path is written absolute" "content=\"$T/plain.md\"" "$(cat "$T/rel.html" 2>/dev/null)"

echo "== every line of the md reaches the page =="
printf '# Spec\n\n### Third level\n\nUnder the third level.\n%s' "$DSECT" > "$T/h3.md"
out="$(gen "$T/h3.md" "$T/h3.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "a third-level heading generates" || fail "a third-level heading generates" "$out"
has "a heading below the second level is a heading" "<h3>Third level</h3>" "$(cat "$T/h3.html" 2>/dev/null)"
printf '# Spec\n\n## At a glance\n\nA paragraph in the card.\n\n1. a numbered line\n- a bullet\n\n## Next\n\nAfter the card.\n%s' "$DSECT" > "$T/lines.md"
gen "$T/lines.md" "$T/lines.html" >/dev/null
page="$(cat "$T/lines.html" 2>/dev/null)"
has "the section after the card still renders" "After the card." "$page"
has "a paragraph in the At a glance card is kept" "A paragraph in the card." "$page"
has "a numbered line in the At a glance card is kept" "a numbered line" "$page"

echo "== round trip through chief-route.ts =="
got="$(read_marker "$T/plain.html")"
has "the reader resolves the marker to the md" "has no spec critic file ($T/plain.md.critic-spec-r<n>.md)" "$got"

echo "== escaping =="
awk -v d="$DSECT" 'BEGIN{print "# Odd name"; printf "%s", d}' > "$T/a\"b&c'd<e>f.md"
gen "$T/a\"b&c'd<e>f.md" "$T/odd.html" >/dev/null
page="$(cat "$T/odd.html" 2>/dev/null)"
has "quote, ampersand, apostrophe and angle brackets are escaped in the marker" "content=\"$T/a&quot;b&amp;c&#39;d&lt;e&gt;f.md\"" "$page"
got="$(read_marker "$T/odd.html")"
has "the reader gets the odd path back unchanged" "has no spec critic file ($T/a\"b&c'd<e>f.md.critic-spec-r<n>.md)" "$got"

echo "== critic seals =="
S="$T/seal"; mkdir -p "$S" "$T/elsewhere"
printf '# Sealed spec\n\nBody.\n%s' "$DSECT" > "$S/s.md"
gen "$S/s.md" "$S/s.html" >/dev/null
msha="$(sha256sum "$S/s.md" | cut -d' ' -f1)"; psha="$(sha256sum "$S/s.html" | cut -d' ' -f1)"
printf 'PLAN critic read %s\nCONTENT-SHA256 %s s.md\nPLAN CLEAN\n' "$msha" "$msha" > "$S/s.md.critic-plan-r1.md"
printf 'SPEC critic read %s\nCONTENT-SHA256 %s s.md\nSPEC CLEAN\n' "$msha" "$msha" > "$S/s.md.critic-spec-r1.md"
got="$(read_marker "$S/s.html")"
has "a critic sealing only the md is refused" "has no seal for the bytes of s.html" "$got"
printf 'SPEC critic read %s and %s\nCONTENT-SHA256 %s s.md\nCONTENT-SHA256 %s s.html\nSPEC CLEAN\n' "$msha" "$psha" "$msha" "$psha" > "$S/s.md.critic-spec-r1.md"
got="$(read_marker "$S/s.html")"
[ "$got" = "OK" ] && pass "a critic sealing the md and the page passes" || fail "a critic sealing the md and the page passes" "$got"
cp "$S/s.html" "$T/elsewhere/renamed.html"
got="$(read_marker "$T/elsewhere/renamed.html")"
[ "$got" = "OK" ] && pass "a copy outside the registered folders, under another name, passes" || fail "a copy outside the registered folders, under another name, passes" "$got"
printf '<!-- edited after the critic -->' >> "$T/elsewhere/renamed.html"
got="$(read_marker "$T/elsewhere/renamed.html")"
has "a copy edited after the critic read it is refused" "has no seal for the bytes of renamed.html" "$got"

echo "== dark by default =="
# The first :root rule is what a reader sees with no choice and any system preference; print alone goes back to light.
DARK="$T/dark-check.ts"
cat > "$DARK" <<'TS'
import { readFileSync } from "node:fs";
const html = readFileSync(process.argv[2], "utf8");
const root = /:root\s*\{([^}]*)\}/.exec(html)?.[1] ?? "";
const val = (v: string) => new RegExp(`${v}\\s*:\\s*(#[0-9a-fA-F]{6})`).exec(root)?.[1];
const lum = (h: string) => { const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((x) => (x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
const ratio = (a: string, b: string) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const [bg, ink, mute, blue] = ["--bg", "--ink", "--mute", "--blue"].map(val);
const why: string[] = [];
if (!bg || !ink || !mute || !blue) why.push("the first :root rule lacks a palette");
else {
  if (lum(bg) > 0.1) why.push(`background ${bg} is light`);
  for (const [n, c] of [["ink", ink], ["mute", mute], ["blue", blue]] as const) if (ratio(c, bg) < 4.5) why.push(`${n} ${c} on ${bg} is ${ratio(c, bg).toFixed(2)}`);
}
if (/prefers-color-scheme/.test(html)) why.push("the page follows a system preference");
if (!/@media print\{:root\{[^}]*--bg:#fff/.test(html)) why.push("print does not go back to a white page");
console.log(why.length ? `DARK-BAD ${why.join("; ")}` : "DARK-OK");
TS
gen "$T/plain.md" "$T/dark.html" >/dev/null
got="$(bun "$DARK" "$T/dark.html" 2>&1)"
[ "$got" = "DARK-OK" ] && pass "the page is dark with readable text and a light print" || fail "the page is dark with readable text and a light print" "$got"

echo "== diagram =="
mkspec() { printf '# Diagram spec\n\n## Diagrams\n\n```svg\n%s\n```\n\n## After\n\nAfter the diagram.\n' "$2" > "$1"; }
mkspec "$T/diag.md" "$DIAG"
out="$(gen "$T/diag.md" "$T/diag.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "m: a spec with an svg fence under ## Diagrams generates" || fail "m: a spec with an svg fence under ## Diagrams generates" "$out"
page="$(cat "$T/diag.html" 2>/dev/null)"
has "m: the page draws the fence's bytes in a figure" "<figure>$DIAG</figure>" "$page"
has "m: the section after the diagram still renders" "After the diagram." "$page"
printf '# No diagram\n\n## Section\n\nBody.\n' > "$T/nodiagram.md"
out="$(gen "$T/nodiagram.md" "$T/nodiagram.html")"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/nodiagram.html" ] && pass "n: a spec with no svg fence is refused and writes no page" || fail "n: a spec with no svg fence is refused and writes no page" "$out"
has "n: the refusal names the file" "nodiagram.md" "$out"
has "n: the refusal says there is no diagram under ## Diagrams" "no svg fence under ## Diagrams" "$out"
printf '# Elsewhere\n\n## Elsewhere\n\n```svg\n%s\n```\n' "$DIAG" > "$T/elsewhere.md"
out="$(gen "$T/elsewhere.md" "$T/elsewhere.html")"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/elsewhere.html" ] && pass "n: an svg fence under another heading is refused" || fail "n: an svg fence under another heading is refused" "$out"
printf '# Control\n\n## Diagrams\n\n```svg\n%s\n```\n\n```bash\n<svg onload="x()">\n```\n\n    ```svg\n    <svg onload="y()">\n    ```\n\n```markdown\n    ```svg\n    <svg onload="z()">\n    ```\n```\n' "$DIAG" > "$T/control.md"
out="$(gen "$T/control.md" "$T/control.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "o: a spec with a good diagram and svg text elsewhere generates" || fail "o: a spec with a good diagram and svg text elsewhere generates" "$out"
page="$(cat "$T/control.html" 2>/dev/null)"
for c in x y z; do
  has "o: the svg text in the $c fence stays escaped text" "&lt;svg onload=\"$c()\"" "$page"
  lacks "o: no raw svg onload for $c" "<svg onload=\"$c()\"" "$page"
done
p_case() { # p_case <name> <svg>: refused, no page
  mkspec "$T/unsafe-$1.md" "$2"
  out="$(gen "$T/unsafe-$1.md" "$T/unsafe-$1.html")"; rc=$?
  [ "$rc" -ne 0 ] && [ ! -e "$T/unsafe-$1.html" ] && pass "p: an svg fence holding $1 is refused and writes no page" || fail "p: an svg fence holding $1 is refused and writes no page" "$out"
}
SV='<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10">'
p_case script "$SV<script>x()</script></svg>"
has "p: the refusal names the file and the fence's line" "unsafe-script.md:5" "$out"
p_case onload '<svg xmlns="http://www.w3.org/2000/svg" onload="x()"><rect/></svg>'
p_case foreignObject "$SV<foreignObject><p>x</p></foreignObject></svg>"
p_case a-xlink-href "$SV<a xlink:href=\"https://x.test/\"><rect/></a></svg>"
p_case path-xlink-href "$SV<path xlink:href=\"https://x.test/\" d=\"M0,0\"/></svg>"
p_case style-attribute "$SV<rect style=\"fill:red\"/></svg>"
p_case url-fill "$SV<rect fill=\"url(https://x.test/a)\"/></svg>"
p_case URL-fill "$SV<rect fill=\"URL(https://x.test/a)\"/></svg>"
p_case css-escape-fill "$SV<rect fill=\"\\75rl(https://x.test/a)\"/></svg>"
p_case char-ref-fill "$SV<rect fill=\"&#117;rl(https://x.test/a)\"/></svg>"
p_case cursor-url "$SV<rect cursor=\"url(https://x.test/c),auto\"/></svg>"
p_case comment "$SV<!-- x --></svg>"
p_case cdata "$SV<text><![CDATA[x]]></text></svg>"
p_case root-not-svg '<div>x</div>'
p_case broken-xml '<svg><rect></svg>'
printf '# Unclosed\n\n## Diagrams\n\n```svg\n%s\n' "$DIAG" > "$T/unsafe-unclosed.md"
out="$(gen "$T/unsafe-unclosed.md" "$T/unsafe-unclosed.html")"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/unsafe-unclosed.html" ] && pass "p: an svg fence never closed is refused and writes no page" || fail "p: an svg fence never closed is refused and writes no page" "$out"
CSP="$(grep -o '<meta http-equiv="Content-Security-Policy" content="[^"]*">' "$ROUTE" | head -n 1)"
[ -n "$CSP" ] && pass "q: the CSP meta is read out of chief-route.ts" || fail "q: the CSP meta is read out of chief-route.ts"
page="$(cat "$T/diag.html" 2>/dev/null)"
has "q: the page carries the same meta byte for byte" "$CSP" "$page"
has "q: the meta is the element right after the charset meta in the head" "<head><meta charset=\"utf-8\">$CSP" "$page"

echo
printf 'passed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
