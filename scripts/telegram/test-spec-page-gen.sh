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

printf '# Plain spec\n\n## Section\n\nSome **bold** text and `code`.\n\n- one\n- two\n' > "$T/plain.md"

echo "== marker =="
out="$(gen "$T/plain.md" "$T/plain.html")"
page="$(cat "$T/plain.html" 2>/dev/null)"
has "the page carries the spec-source marker with the md's absolute path" "<meta name=\"spec-source\" content=\"$T/plain.md\">" "$page"
has "the generator prints the sha256 of the md it read" "$(sha256sum "$T/plain.md" | cut -d' ' -f1)" "$out"
lacks "the page does not say Not for signature" "ot for signature" "$page"

echo "== md without a draft line =="
printf -- '---\ntickets: HIMMEL-1\n---\n\n# Spec with front matter\n\nBody.\n' > "$T/fm.md"
out="$(gen "$T/fm.md" "$T/fm.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "an md carrying no status line generates" || fail "an md carrying no status line generates" "$out"
(cd "$T" && gen plain.md rel.html >/dev/null); has "a relative md path is written absolute" "content=\"$T/plain.md\"" "$(cat "$T/rel.html" 2>/dev/null)"

echo "== every line of the md reaches the page =="
printf '# Spec\n\n### Third level\n\nUnder the third level.\n' > "$T/h3.md"
out="$(gen "$T/h3.md" "$T/h3.html")"; rc=$?
[ "$rc" -eq 0 ] && pass "a third-level heading generates" || fail "a third-level heading generates" "$out"
has "a heading below the second level is a heading" "<h3>Third level</h3>" "$(cat "$T/h3.html" 2>/dev/null)"
printf '# Spec\n\n## At a glance\n\nA paragraph in the card.\n\n1. a numbered line\n- a bullet\n\n## Next\n\nAfter the card.\n' > "$T/lines.md"
gen "$T/lines.md" "$T/lines.html" >/dev/null
page="$(cat "$T/lines.html" 2>/dev/null)"
has "the section after the card still renders" "After the card." "$page"
has "a paragraph in the At a glance card is kept" "A paragraph in the card." "$page"
has "a numbered line in the At a glance card is kept" "a numbered line" "$page"

echo "== round trip through chief-route.ts =="
got="$(read_marker "$T/plain.html")"
has "the reader resolves the marker to the md" "has no spec critic file ($T/plain.md.critic-spec-r<n>.md)" "$got"

echo "== escaping =="
awk 'BEGIN{print "# Odd name"}' > "$T/a\"b&c'd<e>f.md"
gen "$T/a\"b&c'd<e>f.md" "$T/odd.html" >/dev/null
page="$(cat "$T/odd.html" 2>/dev/null)"
has "quote, ampersand, apostrophe and angle brackets are escaped in the marker" "content=\"$T/a&quot;b&amp;c&#39;d&lt;e&gt;f.md\"" "$page"
got="$(read_marker "$T/odd.html")"
has "the reader gets the odd path back unchanged" "has no spec critic file ($T/a\"b&c'd<e>f.md.critic-spec-r<n>.md)" "$got"

echo
printf 'passed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
